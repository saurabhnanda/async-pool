{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Data.TaskPool.Internal where

import           Control.Applicative hiding (empty)
import           Control.Concurrent.Async
import           Control.Concurrent.STM
import           Control.Exception
import           Control.Monad hiding (forM, mapM_)
import           Data.Foldable
import           Data.Graph.Inductive.Graph as Gr hiding ((&))
import           Data.Graph.Inductive.PatriciaTree
import           Data.IntMap (IntMap)
import qualified Data.IntMap as IntMap
import           Data.Maybe (mapMaybe)
import           Data.Monoid
import           Data.Traversable
-- import           Debug.Trace
import           Prelude hiding (mapM_, mapM, foldr, all, any, concatMap)

-- | A 'Handle' is a unique reference to a task that has submitted to a
--   'Pool'.
type Handle = Node
type TaskInfo a = (Handle, Task a)
type TaskGraph a = Gr (Task a) Status

newtype Task a = Task (IO a)

instance Show (Task a) where
    show _ = "Task"

data Status = Pending | Completed deriving (Eq, Show)

-- | A 'Pool' manages a collection of possibly interdependent tasks, such that
--   tasks await execution until the tasks they depend on have finished (and
--   tasks may depend on an arbitrary number of other tasks), while
--   independent tasks execute concurrently up to the number of available
--   resource slots in the pool.
--
--   Results from each task are available until the status of the task is
--   polled or waited on.  Further, the results are kept until that occurs, so
--   failing to ever wait will result in a memory leak.
--
--   Tasks may be cancelled, in which case all dependent tasks are
--   unscheduled.
data Pool a = Pool
    { slots  :: TVar Int
      -- ^ The total number of execution slots in the pool.  If nothing is
      --   running, this is also the number of available slots.  This can be
      --   changed dynamically using 'setPoolSlots'.
    , avail  :: TVar Int
      -- ^ The number of available execution slots in the pool.
    , procs  :: TVar (IntMap (Async a))
      -- ^ The active or completed process table.  For every task running in a
      --   thread, this holds the Async value governing that thread; for every
      --   completed task, it holds the Async value that records its
      --   completion value or exception status.  These entries are inserted
      --   whenever a thread is started, and are cleared by ultimately calling
      --   'pollTaskEither' (which all the other polling and waiting functions
      --   also call).
      --
      --   Note that submitting a task with 'submitTask_' or
      --   'submitDependentTask_' will remove the thread's Async value
      --   immediately at the end of the task, causing it to be garbage
      --   collected.
    , tasks  :: TVar (TaskGraph a)
      -- ^ The task graph represents a partially ordered set P with subset S
      --   such that for every x ∈ S and y ∈ P, either x ≤ y or x is unrelated
      --   to y.  Stated more simply, S is the set of least elements of all
      --   maximal chains in P.  In our case, ≤ relates two uncompleted tasks
      --   by dependency.  Therefore, S is equal to the set of tasks which may
      --   execute concurrently, as none of them have incomplete dependencies.
      --
      --   We use a graph representation to make determination of S more
      --   efficient (where S is just the set of roots in P expressed as a
      --   graph).  Completion status is recorded on the edges, and nodes are
      --   removed from the graph once no other incomplete node depends on
      --   them.
    , tokens :: TVar Int
      -- ^ Tokens identify tasks, and are provisioned monotonically.
    }

-- | Return a list of unlabeled nodes ready for execution.  This decreases the
--   number of available slots, but does not remove the nodes from the graph.
getReadyNodes :: Pool a -> TaskGraph a -> STM [Node]
getReadyNodes p g = do
    availSlots <- readTVar (avail p)
    ps <- readTVar (procs p)
    -- unless (null (nodes g)) $
    --     trace ("Nodes: " ++ show (nodes g)) $ return ()
    let readyNodes = take availSlots
                   $ filter (\n -> isReady n && IntMap.notMember n ps)
                   $ nodes g
    modifyTVar (avail p) (\x -> x - length readyNodes)
    return readyNodes
  where
    -- | Returns True for every node for which there are no dependencies or
    --   incomplete dependencies, and which is not itself a completed
    --   dependency.  The reason for the latter condition is that we keep
    --   completed nodes with dependents in graph until their dependents have
    --   completed (recursively), so that the dependent knows only to begin
    --   when its parent has truly finished -- a fact which cannot be
    --   determined using only the process map.
    isReady x = all isCompleted (inn g x) && not (any isCompleted (out g x))

    isCompleted (_,_,Completed) = True
    isCompleted (_,_,_)         = False

-- | Given a task handle, return everything we know about that task.
getTaskInfo :: TaskGraph a -> Handle -> TaskInfo a
getTaskInfo g h = let (_toNode, _, t, _fromNode) = context g h in (h, t)

-- | Return information about the list of tasks ready to execute, sufficient
--   to start them and remove them from the graph afterwards.
getReadyTasks :: Pool a -> STM [TaskInfo a]
getReadyTasks p = do
    g <- readTVar (tasks p)
    map (getTaskInfo g) <$> getReadyNodes p g

-- | Begin executing tasks in the given pool.  The number of slots determines
--   how many threads may execute concurrently.  This number is adjustable
--   dynamically, by calling 'setPoolSlots', though reducing it does not cause
--   already active threads to stop.
runPool :: Pool a -> IO ()
runPool p = forever $ do
    ready <- atomically $ do
        cnt <- readTVar (slots p)
        check (cnt > 0)
        ready <- getReadyTasks p
        check (not (null ready))
        return ready
    -- unless (null ready) $
    --     trace ("Ready tasks: " ++ show ready) $ return ()
    xs <- forM ready $ \ti -> (,) <$> pure ti <*> startTask p ti
    atomically $ modifyTVar (procs p) $ \ms ->
        foldl' (\m ((h, _), x) -> IntMap.insert h x m) ms xs

-- | Start a task within the given pool.  This begins execution as soon as the
--   runtime is able to.
startTask :: Pool a -> TaskInfo a -> IO (Async a)
startTask p (h, Task go) = async $ finally go $ atomically $ do
    ss <- readTVar (slots p)
    modifyTVar (avail p) $ \a -> min (succ a) ss

    -- Once the task is done executing, we must alter the graph so any
    -- dependent children will know their parent has completed.
    modifyTVar (tasks p) $ \g ->
        case zip (repeat h) (Gr.suc g h) of
            -- If nothing dependend on this task, prune it from the graph, as
            -- well as any parents which now have no dependents.  Otherwise,
            -- mark the edges as Completed so dependent children can execute.
            [] -> dropTask h g
            es -> insEdges (completeEdges es) $ delEdges es g
  where
    completeEdges = map (\(f, t) -> (f, t, Completed))

    dropTask k gr = foldl' f (delNode k gr) (Gr.pre gr k)
      where
        f g n = if outdeg g n == 0 then dropTask n g else g

-- | Create a thread pool for executing interdependent tasks concurrently.
--   The number of available slots governs how many tasks may run at one time.
createPool :: Int                -- ^ Maximum number of running tasks.
           -> IO (Pool a)
createPool cnt = atomically $
    Pool <$> newTVar cnt
         <*> newTVar cnt
         <*> newTVar mempty
         <*> newTVar Gr.empty
         <*> newTVar 0

-- | Set the number of available execution slots in the given 'Pool'.
--   Increasing the number will cause waiting threads to start executing
--   immediately, while decreasing the number only decreases any available
--   slots -- it does not cancel already executing threads.
setPoolSlots :: Pool a -> Int -> STM ()
setPoolSlots p n = do
    ss <- readTVar (slots p)
    let diff = n - ss
    modifyTVar (avail p) (\x -> max 0 (x + diff))
    writeTVar (slots p) (max 0 n)

-- | Cancel every running thread in the pool and unschedule any that had not
--   begun yet.
cancelAll :: Pool a -> IO ()
cancelAll p = (mapM_ cancel =<<) $ atomically $ do
    writeTVar (tasks p) Gr.empty
    xs <- IntMap.elems <$> readTVar (procs p)
    writeTVar (procs p) mempty
    return xs

-- | Cancel a task submitted to the pool.  This will unschedule it if it had not
--   begun yet, or cancel its thread if it had.
cancelTask :: Pool a -> Handle -> IO ()
cancelTask p h = (mapM_ cancel =<<) $ atomically $ do
    g <- readTVar (tasks p)
    hs <- if gelem h g
          then do
              let xs = nodeList g h
              modifyTVar (tasks p) $ \g' -> foldl' (flip delNode) g' xs
              return xs
          else return []
    ps <- readTVar (procs p)
    let ts = mapMaybe (`IntMap.lookup` ps) hs
    writeTVar (procs p) (foldl' (flip IntMap.delete) ps hs)
    return ts
  where
    nodeList :: TaskGraph a -> Node -> [Node]
    nodeList g k = k : concatMap (nodeList g) (Gr.suc g k)

-- | Return the next available thread identifier from the pool.  These are
--   monotonically increasing integers.
nextIdent :: Pool a -> STM Int
nextIdent p = do
    tok <- readTVar (tokens p)
    writeTVar (tokens p) (succ tok)
    return tok

-- | Submit an 'IO' action for execution within the managed thread pool.  When
--   it actually begins executes is determined by the number of available
--   slots, whether the threaded runtime is being used, and how long it takes
--   the jobs before it to complete.
submitTask :: Pool a -> IO a -> STM Handle
submitTask p action = do
    h <- nextIdent p
    modifyTVar (tasks p) (insNode (h, Task action))
    return h

-- | Submit an 'IO ()' action, where we will never care about the result value
--   or if an exception occurred within the task.  This means its process
--   table entry is automatically cleared immediately upon completion of the
--   task.  Use this if you are doing your own result propagation, such as
--   writing to a 'TChan' within the task.
submitTask_ :: Pool a -> IO a -> STM Handle
submitTask_ p action = do
    v <- newEmptyTMVar
    h <- submitTask p (go v)
    putTMVar v h
    return h
  where
    go v = do
        res <- action
        atomically $ do
            h <- takeTMVar v
            res <$ modifyTVar (procs p) (IntMap.delete h)

-- | Given parent and child task handles, link them so that the child cannot
--   execute until the parent has finished.
sequenceTasks :: Pool a
              -> Handle          -- ^ Task we must wait on (the parent)
              -> Handle          -- ^ Task doing the waiting
              -> STM ()
sequenceTasks p parent child = do
    g <- readTVar (tasks p)
    -- If the parent is no longer in the graph, there is no need to establish
    -- a dependency.  The child can begin executing in the next free slot.
    when (gelem parent g) $
        modifyTVar (tasks p) (insEdge (parent, child, Pending))

-- | Submit a task, but only allow it begin executing once its parent task has
--   completed.  This is equivalent to submitting a new task and linking it to
--   its parent using 'sequenceTasks' within a single STM transaction.
submitDependentTask :: Pool a -> Handle -> IO a -> STM Handle
submitDependentTask p parent t = do
    child <- submitTask p t
    sequenceTasks p parent child
    return child

-- | Submit a dependent task where we do not care about the result value or if
--   an exception occurred.  See 'submitTask_'.
submitDependentTask_ :: Pool a -> Handle -> IO a -> STM Handle
submitDependentTask_ p parent t = do
    child <- submitTask_ p t
    sequenceTasks p parent child
    return child

-- | Poll the given task, returning 'Nothing' if it hasn't started yet or is
--   currently executing, and a 'Just' value if a final result is known.
pollTaskEither :: Pool a -> Handle -> STM (Maybe (Either SomeException a))
pollTaskEither p h = do
    ps <- readTVar (procs p)
    case IntMap.lookup h ps of
        Just t  -> do
            -- First check if this is a currently executing task
            mres <- pollSTM t
            case mres of
                -- Task handles are removed when the user has inspected their
                -- contents.  Otherwise, they remain in the table as zombies,
                -- just as happens on Unix.
                Just _  -> modifyTVar (procs p) (IntMap.delete h)
                Nothing -> return ()
            return mres

        Nothing -> do
            -- If not, see if it's a pending task.  If not, do not wait at all
            -- because it will never start!
            g <- readTVar (tasks p)
            return $ if gelem h g
                     then Nothing
                     else Just $ Left $ toException $
                          userError $ "Task " ++ show h ++ " unknown"

-- | Poll the given task, as with 'pollTaskEither', but re-raise any
--   exceptions that were raised in the task's thread.
pollTask :: Pool a -> Handle -> STM (Maybe a)
pollTask p h = do
    mres <- pollTaskEither p h
    case mres of
        Just (Left e)  -> throw e
        Just (Right x) -> return $ Just x
        Nothing        -> return Nothing

-- | Wait until the given task has completed, then return its final status.
waitTaskEither :: Pool a -> Handle -> STM (Either SomeException a)
waitTaskEither p h = do
    mres <- pollTaskEither p h
    case mres of
        Nothing -> retry
        Just x  -> return x

-- | Wait until the given task is completed, but re-raise any exceptions that
--   were raised in the task's thread.
waitTask :: Pool a -> Handle -> STM a
waitTask p h = do
    mres <- waitTaskEither p h
    case mres of
        Left e  -> throw e
        Right x -> return x

-- | Run a group of up to N tasks at a time concurrently, returning the
--   results in order.  Note that the order of actual execution is random.
mapTasks :: Int -> [IO a] -> IO [a]
mapTasks n fs = do
    p <- createPool n
    link =<< async (runPool p)
    hs <- forM fs $ atomically . submitTask p
    forM hs $ atomically . waitTask p
