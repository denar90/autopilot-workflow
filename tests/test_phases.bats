#!/usr/bin/env bats

load helpers

setup() {
  source "$LIB_DIR/phases.sh"
}

@test "phase_index returns 0 for 'none'" {
  run phase_index none
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "phase_index returns monotonic ranks" {
  a=$(phase_index worktree_done)
  b=$(phase_index research_done)
  c=$(phase_index plan_done)
  [ "$a" -lt "$b" ]
  [ "$b" -lt "$c" ]
}

@test "phase_lt is strict less-than" {
  run phase_lt none worktree_done
  [ "$status" -eq 0 ]
  run phase_lt worktree_done worktree_done
  [ "$status" -ne 0 ]
  run phase_lt research_done worktree_done
  [ "$status" -ne 0 ]
}

@test "phase_index errors on unknown phase" {
  run phase_index gibberish_phase
  [ "$status" -ne 0 ]
}

@test "all canonical phases are recognized" {
  for p in none worktree_done research_done plan_done plan_approved \
           implement_done review_cycle_1_done review_cycle_2_done \
           review_cycle_3_done visual_verify_done review_approved merged; do
    run phase_index "$p"
    [ "$status" -eq 0 ]
  done
}

@test "visual_verify_done sits between review cycles and review_approved" {
  a=$(phase_index review_cycle_3_done)
  b=$(phase_index visual_verify_done)
  c=$(phase_index review_approved)
  [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ]
}
