---------------------------- MODULE PromoteFence ----------------------------
(***************************************************************************)
(* Promotes to one branch racing fence updates (src/promote.zig).         *)
(*                                                                         *)
(* A promoter plans against the fence epoch and branch head it reads      *)
(* (GET .../fence and the branch), then asks gitd to promote. gitd lands  *)
(* the promote only if the fence is unpaused, the epoch is still the one   *)
(* planned against, and the branch is still at the planned base. An admin  *)
(* may pause, unpause, or bump the epoch at any time.                      *)
(*                                                                         *)
(* With LOCKED = TRUE, gitd holds `App.promote_lock` across the fence     *)
(* check and the ref move, and fence updates take the same lock, so the   *)
(* check and the move are one step. With LOCKED = FALSE they are two      *)
(* steps, which is the bug the model must catch: a fence update between   *)
(* them lets a promote land while paused or under a newer epoch.          *)
(*                                                                         *)
(* The ref move is a compare-and-swap in both cases (R3.2,                 *)
(* tests/tla/commit_cas).                                                  *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS Promoters,   \* promoter ids, which double as their candidate commits
          MaxEpoch,    \* bounds how often the admin changes the fence
          LOCKED       \* TRUE: gitd's promote_lock; FALSE: check, then move

Root == 0              \* the commit the branch starts at

VARIABLES head,        \* the commit the branch points at
          paused,      \* the fence's paused flag
          epoch,       \* the fence's policy epoch
          pc,          \* "plan" | "check" | "move" | "done"
          plan,        \* plan[p]: the epoch and base p promotes against
          landed,      \* the fence as it was when each promote moved the branch
          moves        \* moves[p]: how often p's promote moved the branch

vars == <<head, paused, epoch, pc, plan, landed, moves>>

Init == /\ head = Root
        /\ paused = FALSE
        /\ epoch = 0
        /\ pc = [p \in Promoters |-> "plan"]
        /\ plan = [p \in Promoters |-> [epoch |-> 0, base |-> Root]]
        /\ landed = {}
        /\ moves = [p \in Promoters |-> 0]

\* The promoter reads the fence and the head, outside gitd's lock.
Plan(p) == /\ pc[p] = "plan"
           /\ plan' = [plan EXCEPT ![p] = [epoch |-> epoch, base |-> head]]
           /\ pc' = [pc EXCEPT ![p] = "check"]
           /\ UNCHANGED <<head, paused, epoch, landed, moves>>

FenceOk(p) == ~paused /\ epoch = plan[p].epoch

\* The ref compare-and-swap: move only from the planned base.
Land(p) == /\ head' = p
           /\ landed' = landed \cup {[who |-> p, epoch |-> epoch, paused |-> paused]}
           /\ moves' = [moves EXCEPT ![p] = @ + 1]

\* gitd under promote_lock: the check and the move are one step. A failed
\* check is a 409 and changes nothing.
CheckAndMove(p) == /\ LOCKED
                   /\ pc[p] = "check"
                   /\ pc' = [pc EXCEPT ![p] = "done"]
                   /\ IF FenceOk(p) /\ head = plan[p].base
                         THEN Land(p)
                         ELSE UNCHANGED <<head, landed, moves>>
                   /\ UNCHANGED <<paused, epoch, plan>>

\* Without the lock: check the fence ...
Check(p) == /\ ~LOCKED
            /\ pc[p] = "check"
            /\ pc' = [pc EXCEPT ![p] = IF FenceOk(p) THEN "move" ELSE "done"]
            /\ UNCHANGED <<head, paused, epoch, plan, landed, moves>>

\* ... and later move the ref, while the fence may have changed.
Move(p) == /\ ~LOCKED
           /\ pc[p] = "move"
           /\ pc' = [pc EXCEPT ![p] = "done"]
           /\ IF head = plan[p].base THEN Land(p) ELSE UNCHANGED <<head, landed, moves>>
           /\ UNCHANGED <<paused, epoch, plan>>

\* Fence updates. Changing paused, or a bump, raises the epoch.
Pause == /\ ~paused /\ epoch < MaxEpoch
         /\ paused' = TRUE /\ epoch' = epoch + 1
         /\ UNCHANGED <<head, pc, plan, landed, moves>>
Unpause == /\ paused /\ epoch < MaxEpoch
           /\ paused' = FALSE /\ epoch' = epoch + 1
           /\ UNCHANGED <<head, pc, plan, landed, moves>>
Bump == /\ epoch < MaxEpoch
        /\ epoch' = epoch + 1
        /\ UNCHANGED <<head, paused, pc, plan, landed, moves>>

Next == \/ Pause \/ Unpause \/ Bump
        \/ \E p \in Promoters : Plan(p) \/ CheckAndMove(p) \/ Check(p) \/ Move(p)

Spec == Init /\ [][Next]_vars

TypeOK == /\ head \in Promoters \cup {Root}
          /\ paused \in BOOLEAN
          /\ epoch \in 0..MaxEpoch
          /\ pc \in [Promoters -> {"plan", "check", "move", "done"}]

\* Every promote that moved the branch did so while the fence was unpaused
\* and at the epoch it was planned against.
NoStalePromote == \A l \in landed : ~l.paused /\ l.epoch = plan[l.who].epoch

\* A promote moves the branch at most once.
MoveOnce == \A p \in Promoters : moves[p] <= 1

\* The branch only ever points at a promoted candidate (or the root).
HeadLanded == head = Root \/ \E l \in landed : l.who = head
=============================================================================
