# Run with: openroad -no_init -no_splash -exit solution/tests/test_batches.tcl
# Exercise the real batch transaction without loading a benchmark.
set path [file join [file dirname [info script]] .. optimizer.tcl]
set fp [open $path r]
set code [read $fp]
close $fp
if {![regsub {optimizer::run\s*$} $code {} code]} { error "Cannot isolate optimizer procedures" }
eval $code

proc assert_equal {actual expected message} {
    if {$actual ne $expected} { error "$message: expected <$expected>, got <$actual>" }
}
proc test_master_R {method} { return R }
proc test_master_L {method} { return L }
set current [dict create]
set fail_swap 0
set unsafe_hold 0
proc test_inst {name method args} {
    if {$method eq "getMaster"} { return [dict get $::current $name] }
    if {$method eq "swapMaster"} {
        set target [lindex $args 0]
        if {$::fail_swap && $name eq "bad" && $target eq "test_master_L"} { return 0 }
        dict set ::current $name $target
        return 1
    }
    error "Unexpected mock instance operation: $method"
}
proc test_block {method name} {
    if {$method ne "findInst"} { error "Unexpected mock block operation" }
    return test_$name
}
interp alias {} test_good {} test_inst good
interp alias {} test_bad {} test_inst bad
proc optimizer::timing_metrics {} {
    set value 0
    dict for {name master} $::current {
        if {$master eq "test_master_L"} {
            if {$name eq "bad"} { incr value -10 } else { incr value }
        }
    }
    set metrics [dict create BC [list $value 0 0 0] TC {0 0 0 0} WC {0 0 0 0}]
    if {$::unsafe_hold && [dict get $::current good] eq "test_master_L"} {
        dict set metrics TC {0 0 -1 0}
    }
    return $metrics
}
proc optimizer::objective {metrics baseline} { return [lindex [dict get $metrics BC] 0] }
set baseline [dict create BC {0 0 0 0} TC {0 0 0 0} WC {0 0 0 0}]
set good [list good test_master_R test_master_L]
set bad [list bad test_master_R test_master_L]
set report [file tempfile report_path]

# A successful transaction keeps its swaps.
set ::env(MAX_VT_TRIALS) 4
set current [dict create good test_master_R bad test_master_R]
set state [dict create trials 0 changed 0 score 0]
optimizer::try_batch test_block [list $good] $baseline $report state
assert_equal [dict get $current good] test_master_L "Accepted swap"
assert_equal [dict get $state changed] 1 "Accepted count"
assert_equal [dict get $state trials] 1 "Accepted trial count"

# A failing parent is rolled back before its children are tried.
set current [dict create good test_master_R bad test_master_R]
set state [dict create trials 0 changed 0 score 0]
optimizer::try_batch test_block [list $good $bad] $baseline $report state
assert_equal [dict get $current good] test_master_L "Safe child retained"
assert_equal [dict get $current bad] test_master_R "Unsafe child restored"
assert_equal [dict get $state trials] 3 "Parent and child trial count"
assert_equal [dict get $state changed] 1 "Only safe child counted"

# Reaching the budget prevents recursive work and leaves rejected cells intact.
set ::env(MAX_VT_TRIALS) 1
set current [dict create good test_master_R bad test_master_R]
set state [dict create trials 0 changed 0 score 0]
optimizer::try_batch test_block [list $good $bad] $baseline $report state
assert_equal [dict get $current good] test_master_R "Budget rollback of good cell"
assert_equal [dict get $current bad] test_master_R "Budget rollback of bad cell"
assert_equal [dict get $state trials] 1 "Hard trial cap"
assert_equal [dict get $state changed] 0 "Rejected transaction count"

# A gain in the objective cannot override a hold-WNS violation in another scene.
set current [dict create good test_master_R bad test_master_R]
set unsafe_hold 1
set state [dict create trials 0 changed 0 score 0]
optimizer::try_batch test_block [list $good] $baseline $report state
assert_equal [dict get $current good] test_master_R "Cross-corner hold guard"
assert_equal [dict get $state changed] 0 "Unsafe gain is rejected"
set unsafe_hold 0

# A database error restores swaps that succeeded earlier in the transaction.
set current [dict create good test_master_R bad test_master_R]
set fail_swap 1
set state [dict create trials 0 changed 0 score 0]
set failed [catch {optimizer::try_batch test_block [list $good $bad] $baseline $report state}]
assert_equal $failed 1 "Swap error propagates"
assert_equal [dict get $current good] test_master_R "Rollback after database error"

# Refreshing the ranking changes the next batch without retrying attempted cells
# or exceeding the distinct-cell budget. The fixed planner remains the control.
rename optimizer::batch_plan optimizer::real_batch_plan
rename optimizer::try_batch optimizer::real_try_batch
proc optimizer::batch_plan {block replacements protected baseline excluded limit} {
    incr ::plan_calls
    set result {}
    set names [expr {$::plan_calls == 1 ? "good bad" : "new good bad"}]
    foreach name $names {
        if {[dict exists $excluded $name]} { continue }
        lappend result [list $name test_master_R test_master_L]
        if {[llength $result] >= $limit} { break }
    }
    return $result
}
proc optimizer::try_batch {block batch baseline report state_name} {
    upvar 1 $state_name state
    dict incr state trials
    dict incr state changed [llength $batch]
    foreach item $batch { lappend ::attempts [lindex $item 0] }
}
set ::env(MAX_VT_TRIALS) 2
set ::env(MAX_BATCH_CELLS) 2
set ::env(VT_BATCH_SIZE) 1
foreach {refresh expected calls} {0 {good bad} 1 1 {good new} 2} {
    set ::env(VT_REFRESH_BATCHES) $refresh
    set plan_calls 0
    set attempts {}
    lassign [optimizer::batch_search test_block {} {} $baseline $report] trials changed score
    assert_equal $attempts $expected "Ranking refresh selection"
    assert_equal $plan_calls $calls "Ranking refresh frequency"
    assert_equal $trials 2 "Refresh trial cap"
    assert_equal $changed 2 "Refresh distinct-cell cap"
}
close $report
file delete $report_path
puts "PASS: batch transactions, hold guards, error recovery, and bounded ranking refresh"
