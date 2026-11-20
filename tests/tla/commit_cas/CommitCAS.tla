---------------------------- MODULE CommitCAS ----------------------------
(***************************************************************************)
(* Agents committing to one branch through gitd's commit API (R3.2).      *)
(*                                                                         *)
(* Each agent reads the branch head, builds a commit on it, and asks gitd  *)
(* to move the branch. gitd moves it only if it is still at the head the   *)
(* agent read: `git update-ref <ref> <new> <expected>`, a compare-and-swap  *)
(* under git's ref lock. A loser gets 409 with the current head and may    *)
(* rebuild on it.                                                          *)
(*                                                                         *)
(* With CAS = FALSE the write is blind (`update-ref <ref> <new>`), which   *)
(* is the bug the model must catch: an accepted commit drops out of the    *)
(* branch's history.                                                       *)
(*                                                                         *)
(* Code: src/repo_git.zig `updateRef`, src/content.zig `createCommit`.     *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS Agents,      \* agent ids, which double as their commit ids
          MaxRetries,  \* how often a loser rebuilds on the new head
          CAS          \* TRUE: gitd's compare-and-swap; FALSE: blind write

Root == 0              \* the commit the branch starts at

VARIABLES head,        \* the commit the branch points at
          parent,      \* parent[c]: the commit c was built on
          pc,          \* "read" | "write" | "done"
          seen,        \* the head each agent built on
          accepted,    \* commits gitd accepted (answered 201)
          conflicts,   \* conflicts[a]: 409s agent a has received
          retries

vars == <<head, parent, pc, seen, accepted, conflicts, retries>>

Init == /\ head = Root
        /\ parent = [a \in Agents |-> Root]
        /\ pc = [a \in Agents |-> "read"]
        /\ seen = [a \in Agents |-> Root]
        /\ accepted = {}
        /\ conflicts = [a \in Agents |-> 0]
        /\ retries = [a \in Agents |-> 0]

\* The agent reads the head and builds its commit on it.
Read(a) == /\ pc[a] = "read"
           /\ seen' = [seen EXCEPT ![a] = head]
           /\ parent' = [parent EXCEPT ![a] = head]
           /\ pc' = [pc EXCEPT ![a] = "write"]
           /\ UNCHANGED <<head, accepted, conflicts, retries>>

\* gitd tries to move the branch to the agent's commit.
Write(a) == /\ pc[a] = "write"
            /\ IF ~CAS \/ head = seen[a]
                  THEN /\ head' = a
                       /\ accepted' = accepted \cup {a}
                       /\ pc' = [pc EXCEPT ![a] = "done"]
                       /\ UNCHANGED conflicts
                  ELSE /\ conflicts' = [conflicts EXCEPT ![a] = @ + 1]
                       /\ pc' = [pc EXCEPT ![a] = IF retries[a] < MaxRetries THEN "read" ELSE "done"]
                       /\ UNCHANGED <<head, accepted>>
            /\ retries' = [retries EXCEPT ![a] = IF pc'[a] = "read" THEN @ + 1 ELSE @]
            /\ UNCHANGED <<parent, seen>>

Next == \E a \in Agents : Read(a) \/ Write(a)

Spec == Init /\ [][Next]_vars

\* Commits reachable from c by parent links, c included.
RECURSIVE History(_)
History(c) == IF c = Root THEN {Root} ELSE {c} \cup History(parent[c])

TypeOK == /\ head \in Agents \cup {Root}
          /\ accepted \subseteq Agents
          /\ pc \in [Agents -> {"read", "write", "done"}]

\* No lost update: every commit gitd accepted is still in the branch.
NoLostUpdate == accepted \subseteq History(head)

\* The branch only ever points at an accepted commit (or the root).
HeadAccepted == head \in accepted \cup {Root}

\* Once everyone has finished, somebody won: conflicts never starve all.
SomeoneWins == (\A a \in Agents : pc[a] = "done") => accepted # {}
=============================================================================
