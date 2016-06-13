package ghcvm.runtime.prim;

import java.util.Deque;
import java.util.ArrayDeque;

import ghcvm.runtime.prim.StgMVar;
import ghcvm.runtime.types.StgTSO;
import ghcvm.runtime.closure.StgClosure;
import ghcvm.runtime.closure.StgContext;
import static ghcvm.runtime.RtsMessages.barf;

public class StgMVar extends StgClosure {
    public Deque<StgTSO> tsoQueue = new ArrayDeque<StgTSO>();
    public StgClosure value;

    public StgMVar(StgClosure value) {
        this.value = value;
    }

    @Override
    public void enter(StgContext context) {
        barf("MVAR object entered!");
    }

    public void pushFirst(StgTSO tso) {
        tsoQueue.offerFirst(tso);
    }

    public void pushLast(StgTSO tso) {
        tsoQueue.offerLast(tso);
    }

    public StgTSO popFromQueue() {
        return tsoQueue.poll();
    }
}