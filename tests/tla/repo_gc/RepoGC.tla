---------------------------- MODULE RepoGC ----------------------------
(***************************************************************************)
(* Coordination between garbage collection and repo delete/recreate.       *)
(*                                                                         *)
(* gc runs `git gc` without holding `repo_lock` so other repos are not     *)
(* stalled. To keep GC from running on a deleted or recreated repo (or     *)
(* twice at once on one repo), Coordinator tracks per-repo `gc_running`    *)
(* and `deleting` state under `repo_lock` + a Condition variable.          *)
(*                                                                         *)
(* When SafeProtocol = FALSE, Delete skips waiting for `gc_running`,       *)
(* violating NoGCOnDeletedRepo (and NoCrossIncarnationGC on recreate).     *)
(*                                                                         *)
(* Code: src/maintenance.zig (`Coordinator`), src/server.zig (`deleteRepo`) *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS MaxEpoch,
          SafeProtocol

VARIABLES exists,
          epoch,
          gc_worker,
          gc_epoch,
          gc_running,
          deleting,
          gc_count

vars == <<exists, epoch, gc_worker, gc_epoch, gc_running, deleting, gc_count>>

Init ==
  /\ exists = TRUE
  /\ epoch = 1
  /\ gc_worker = "idle"
  /\ gc_epoch = 0
  /\ gc_running = FALSE
  /\ deleting = FALSE
  /\ gc_count = 0

\* maintenance.beginGc under repo_lock
StartGC ==
  /\ exists
  /\ ~deleting
  /\ ~gc_running
  /\ gc_worker = "idle"
  /\ gc_worker' = "running"
  /\ gc_epoch' = epoch
  /\ gc_running' = TRUE
  /\ gc_count' = gc_count + 1
  /\ UNCHANGED <<exists, epoch, deleting>>

\* maintenance.endGc under repo_lock
FinishGC ==
  /\ gc_worker = "running"
  /\ gc_worker' = "idle"
  /\ gc_running' = FALSE
  /\ gc_count' = gc_count - 1
  /\ UNCHANGED <<exists, epoch, gc_epoch, deleting>>

\* Delete requested while GC is running blocks further StartGC via `deleting`
MarkDeleting ==
  /\ SafeProtocol
  /\ exists
  /\ gc_running
  /\ ~deleting
  /\ deleting' = TRUE
  /\ UNCHANGED <<exists, epoch, gc_worker, gc_epoch, gc_running, gc_count>>

\* server.deleteRepo waits until ~gc_running (when SafeProtocol=TRUE) then removes repo
Delete ==
  /\ exists
  /\ (~SafeProtocol \/ ~gc_running)
  /\ exists' = FALSE
  /\ deleting' = FALSE
  /\ UNCHANGED <<epoch, gc_worker, gc_epoch, gc_running, gc_count>>

\* server.createRepo creates a new incarnation under repo_lock when ~exists
Recreate ==
  /\ ~exists
  /\ epoch < MaxEpoch
  /\ (~SafeProtocol \/ ~gc_running)
  /\ exists' = TRUE
  /\ epoch' = epoch + 1
  /\ UNCHANGED <<gc_worker, gc_epoch, gc_running, deleting, gc_count>>

Next == StartGC \/ FinishGC \/ MarkDeleting \/ Delete \/ Recreate

Spec == Init /\ [][Next]_vars

TypeOK ==
  /\ exists \in BOOLEAN
  /\ epoch \in 1..MaxEpoch
  /\ gc_worker \in {"idle", "running"}
  /\ gc_epoch \in 0..MaxEpoch
  /\ gc_running \in BOOLEAN
  /\ deleting \in BOOLEAN
  /\ gc_count \in {0, 1}

NoGCOnDeletedRepo == (gc_worker = "running") => exists
NoCrossIncarnationGC == (gc_worker = "running") => (gc_epoch = epoch)
NoConcurrentGC == gc_count <= 1
=============================================================================
