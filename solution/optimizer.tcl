# Timing-driven, same-footprint VT search with MCMM setup/hold checks.
namespace eval optimizer {
    variable script_dir [file dirname [file normalize [info script]]]
}

proc optimizer::load_design {} {
    set platform $::env(PLATFORM_DIR)
    # The launcher validates NUM_CORES before starting OpenROAD.
    set_thread_count $::env(NUM_CORES)
    source [file join $platform util liberty_suppressions.tcl]
    source [file join $platform util libraries.tcl]
    foreach lef {
        asap7_tech_1x_201209.lef
        asap7sc7p5t_28_R_1x_220121a.lef
        asap7sc7p5t_28_L_1x_220121a.lef
        asap7sc7p5t_28_SL_1x_220121a.lef
    } {
        read_lef [file join $platform lef $lef]
    }
    foreach corner {TC BC WC} {
        foreach lib $corner_libs($corner) { read_liberty $lib }
    }
    variable libraries
    set libraries [array get corner_libs]

    # Load the complete physical design, including physical-only cells and PDN.
    # DEF/Verilog consistency is independently checked by the contest evaluator.
    read_def $::env(INPUT_DEF)
    if {[[ord::get_db_block] getName] ne $::env(TOP_MODULE)} {
        error "Input DEF does not match TOP_MODULE=$::env(TOP_MODULE)"
    }

    variable grid_patterns
    set grid_patterns [dict create X {} Y {}]
    set grid [[ord::get_db_block] getGCellGrid]
    if {$grid ne "NULL"} {
        foreach axis {X Y} {
            for {set i 0} {$i < [$grid getNumGridPatterns$axis]} {incr i} {
                dict lappend grid_patterns $axis [$grid getGridPattern$axis $i]
            }
        }
    }
    return [ord::get_db_block]
}

proc optimizer::replacement_masters {} {
    set families [dict create]
    variable script_dir
    set groups_path [file join $script_dir .. evaluator third_party displacement asap7_equivalent_cell_list.csv]
    set groups [open $groups_path r]
    while {[gets $groups line] >= 0} {
        set members [split [string trim $line] ,]
        foreach member $members {
            dict set families $member $members
        }
    }
    close $groups

    set masters [dict create]
    foreach lib [[ord::get_db] getLibs] {
        foreach master [$lib getMasters] {
            dict set masters [$master getName] $master
        }
    }

    # Cache approved same-footprint replacements once per master, not per instance.
    set replacements [dict create]
    dict for {name master} $masters {
        if {![dict exists $families $name]} { continue }
        foreach target [dict get $families $name] {
            if {$target eq $name || ![dict exists $masters $target]} { continue }
            set prohibited 0
            foreach pattern {*x1p*_ASAP7* *xp*_ASAP7* SDF* ICG*} {
                if {[string match $pattern $target]} { set prohibited 1; break }
            }
            if {$prohibited} { continue }
            set replacement [dict get $masters $target]
            if {[$master getWidth] == [$replacement getWidth]
                && [$master getHeight] == [$replacement getHeight]} {
                dict lappend replacements $name $replacement
            }
        }
    }

    return $replacements
}

proc optimizer::initialize_timing {} {
    variable libraries
    array set corner_libs $libraries
    source $::env(MCMM_CONFIG)
    foreach corner $mcmm_corners {
        set mode $scenario_mode($corner)
        read_sdc -mode $mode $scenario_sdc($corner)
        set_mode $mode
        foreach clk [all_clocks] {
            if {![get_property $clk is_virtual]} { set_propagated_clock $clk }
        }
        define_scene $corner -mode $mode -liberty $corner_libs($corner)
    }
    set_scene TC
    source [file join $::env(PLATFORM_DIR) util setRC.tcl]
    set_dont_use {*x1p*_ASAP7* *xp*_ASAP7* SDF* ICG*}
    set_routing_layers -signal M2-M7 -clock M4-M7
    set_global_routing_layer_adjustment * 0.25
    set_global_routing_random -seed 42
    global_route -allow_congestion -congestion_iterations 30
    estimate_parasitics -global_routing
}

proc optimizer::timing_metrics {} {
    set result [dict create]
    foreach scene {BC TC WC} {
        dict set result $scene [list [sta::worst_slack -scene $scene -max] \
            [sta::total_negative_slack -scene $scene -max] \
            [sta::worst_slack -scene $scene -min] \
            [sta::total_negative_slack -scene $scene -min]]
    }
    return $result
}

proc optimizer::objective {metrics baseline} {
    set value 0.0
    dict for {scene data} $metrics {
        lassign $data wns tns hold_wns hold_tns
        lassign [dict get $baseline $scene] base_wns base_tns
        set value [expr {$value + ($wns-$base_wns)/max(1.0,abs($base_wns))
            + ($tns-$base_tns)/max(1.0,abs($base_tns))
            - max(0.0,-$hold_wns-10.0)/10.0
            - max(0.0,-$hold_tns-1000.0)/1000.0}]
    }
    return [expr {$value/3.0}]
}

proc optimizer::protected_instances {block} {
    set protected [dict create]
    foreach net [$block getNets] {
        if {[$net getSigType] eq "CLOCK"} {
            foreach pin [$net getITerms] {
                dict set protected [[$pin getInst] getName] 1
            }
        }
    }
    foreach inst [$block getInsts] {
        if {[$inst isDoNotTouch] || [$inst getPlacementStatus] in {FIRM LOCKED}} {
            dict set protected [$inst getName] 1
        }
    }
    return $protected
}

proc optimizer::rank_candidates {block replacements protected baseline} {
    set weights [dict create]
    foreach scene {BC TC WC} {
        foreach delay {max min} {
            # One path per endpoint keeps ranking bounded and spreads effort.
            foreach path [find_timing_paths -scenes $scene -path_delay $delay \
                -group_path_count $::env(VT_PATH_COUNT) -endpoint_path_count 1 -slack_max 0] {
                set slack [get_property $path slack]
                set weight [expr {abs($slack)/max(1.0,abs([lindex [dict get $baseline $scene] 0]))}]
                if {$delay eq "min"} { set weight [expr {abs($slack)/10.0}] }
                set seen [dict create]
                foreach point [get_property $path points] {
                    set pin [get_property $point pin]
                    foreach cell [get_cells -quiet -of_objects $pin] {
                        set inst [sta::sta_to_db_inst $cell]
                        if {$inst eq "NULL"} { continue }
                        set name [$inst getName]
                        if {[dict exists $seen $name] || [dict exists $protected $name]} { continue }
                        dict set seen $name 1
                        if {![dict exists $replacements [[$inst getMaster] getName]]} { continue }
                        set old 0.0
                        if {[dict exists $weights $name]} { set old [dict get $weights $name] }
                        dict set weights $name [expr {$old+$weight}]
                    }
                }
            }
        }
    }
    set result {}
    dict for {name weight} $weights { lappend result [list $weight $name] }
    return [lsort -real -decreasing -index 0 [lsort -ascii -index 1 $result]]
}

# Setup-only sensitivity proxy inspired by Hu et al., ICCAD 2012, Eq. (2).
# Measure each input-to-output cell arc, excluding the intervening wire delay.
# A delay-weighted critical-path count favors bottlenecks; sqrt coverage avoids
# spending the entire budget on a heavily shared cone. This is a proxy for
# delay-change sensitivity, not a Liberty-table prediction of a specific swap.
proc optimizer::sensitivity_candidates {block replacements protected baseline} {
    set gains [dict create]
    set coverage [dict create]
    foreach scene {BC TC WC} {
        set scale [expr {max(1.0,abs([lindex [dict get $baseline $scene] 0]))}]
        foreach path [find_timing_paths -scenes $scene -path_delay max \
            -group_path_count $::env(VT_PATH_COUNT) -endpoint_path_count 1 -slack_max 0] {
            set weight [expr {max(0.05,abs([get_property $path slack])/$scale)}]
            set previous_name ""
            set previous_arrival 0.0
            set seen [dict create]
            foreach point [get_property $path points] {
                set arrival [get_property $point arrival]
                set pin [get_property $point pin]
                set cells [get_cells -quiet -of_objects $pin]
                set inst NULL
                if {[llength $cells] == 1} { set inst [sta::sta_to_db_inst [lindex $cells 0]] }
                if {$inst eq "NULL"} { set previous_name ""; continue }
                set name [$inst getName]
                if {$name eq $previous_name && ![dict exists $seen $name]
                    && ![dict exists $protected $name]
                    && [dict exists $replacements [[$inst getMaster] getName]]} {
                    set iterm [$inst findITerm [get_property $pin lib_pin_name]]
                    if {$iterm ne "NULL" && [[$iterm getMTerm] getIoType] eq "OUTPUT"} {
                        set delay [expr {max(0.0,$arrival-$previous_arrival)}]
                        if {![dict exists $gains $name]} {
                            dict set gains $name 0.0
                            dict set coverage $name 0.0
                        }
                        dict set gains $name [expr {[dict get $gains $name]+$weight*$delay/$scale}]
                        dict set coverage $name [expr {[dict get $coverage $name]+$weight}]
                        dict set seen $name 1
                    }
                }
                set previous_name $name
                set previous_arrival $arrival
            }
        }
    }
    set result {}
    dict for {name gain} $gains {
        if {$gain > 0.0} { lappend result [list [expr {$gain/sqrt([dict get $coverage $name])}] $name] }
    }
    return [lsort -real -decreasing -index 0 [lsort -ascii -index 1 $result]]
}

# High-fanout drivers provide a cheap alternative to walking many timing paths.
proc optimizer::fanout_candidates {block replacements protected baseline} {
    set loads [dict create]
    foreach net [$block getNets] {
        if {[$net getSigType] ne "SIGNAL"} { continue }
        set driver ""
        set drivers 0
        set fanout 0
        foreach pin [$net getITerms] {
            switch -- [[$pin getMTerm] getIoType] {
                INPUT { incr fanout }
                OUTPUT { incr drivers; set driver [$pin getInst] }
                INOUT { incr drivers }
            }
        }
        foreach pin [$net getBTerms] {
            switch -- [$pin getIoType] {
                INPUT - INOUT { incr drivers }
                OUTPUT { incr fanout }
            }
        }
        if {$drivers != 1 || $driver eq "" || $fanout < 6} { continue }
        set name [$driver getName]
        if {[dict exists $protected $name] || ![dict exists $replacements [[$driver getMaster] getName]]} { continue }
        if {![dict exists $loads $name] || $fanout > [dict get $loads $name]} { dict set loads $name $fanout }
    }
    set result {}
    dict for {name fanout} $loads { lappend result [list $fanout $name] }
    return [lsort -integer -decreasing -index 0 [lsort -ascii -index 1 $result]]
}

# An unsuccessful batch is restored completely before its halves are tried.
# The same trial budget bounds both initial batches and recursive refinements.
proc optimizer::try_batch {block batch baseline report state_name} {
    upvar 1 $state_name state
    if {[dict get $state trials] >= $::env(MAX_VT_TRIALS) || ![llength $batch]} { return }
    set applied {}
    try {
        foreach item $batch {
            lassign $item name original target
            set inst [$block findInst $name]
            if {![$inst swapMaster $target]} { error "Batch master swap failed for $name" }
            lappend applied $item
        }
        dict incr state trials
        set metrics [timing_metrics]
        set score [objective $metrics $baseline]
        set safe 1
        foreach scene {BC TC WC} {
            if {[lindex [dict get $metrics $scene] 2] < [lindex [dict get $baseline $scene] 2]-0.2} { set safe 0 }
        }
        if {$safe && $score > [dict get $state score]+0.00001} {
            dict set state score $score
            dict incr state changed [llength $batch]
            foreach item $batch {
                lassign $item name original target
                puts $report "$name\t[$original getName]\t[$target getName]\t$score"
            }
            set applied {}
            puts "Accepted batch: cells=[llength $batch] trials=[dict get $state trials] objective=$score"
            flush stdout
            return
        }
    } finally {
        foreach item $applied {
            lassign $item name original target
            if {![[$block findInst $name] swapMaster $original]} { error "Batch restore failed for $name" }
        }
    }
    if {[llength $batch] > 1 && [dict get $state trials] < $::env(MAX_VT_TRIALS)} {
        set middle [expr {[llength $batch]/2}]
        try_batch $block [lrange $batch 0 [expr {$middle-1}]] $baseline $report state
        try_batch $block [lrange $batch $middle end] $baseline $report state
    }
}

proc optimizer::batch_plan {block replacements protected baseline excluded limit} {
    if {$::env(VT_ORDER) eq "fanout"} {
        set candidates [fanout_candidates $block $replacements $protected $baseline]
    } elseif {$::env(VT_ORDER) eq "sensitivity"} {
        set candidates [sensitivity_candidates $block $replacements $protected $baseline]
    } else {
        set candidates [rank_candidates $block $replacements $protected $baseline]
    }
    set plan {}
    set vt_rank [dict create R 0 L 1 SL 2]
    foreach candidate $candidates {
        lassign $candidate weight name
        if {[dict exists $excluded $name]} { continue }
        set original [[$block findInst $name] getMaster]
        set old_name [$original getName]
        if {![regexp {_(R|L|SL)$} $old_name -> old_vt]
            || [dict get $vt_rank $old_vt] >= [dict get $vt_rank $::env(VT_TARGET)]} { continue }
        regsub {_(R|L|SL)$} $old_name "_$::env(VT_TARGET)" target_name
        foreach target [dict get $replacements $old_name] {
            if {[$target getName] eq $target_name} {
                lappend plan [list $name $original $target]
                break
            }
        }
        if {[llength $plan] >= $limit} { break }
    }
    return $plan
}

proc optimizer::batch_search {block replacements protected baseline report} {
    set plan [batch_plan $block $replacements $protected $baseline {} $::env(MAX_BATCH_CELLS)]
    set state [dict create trials 0 changed 0 score [objective $baseline $baseline]]
    set width $::env(VT_BATCH_SIZE)
    set attempted [dict create]
    set refresh $::env(VT_REFRESH_BATCHES)
    for {set start 0} {$start < [llength $plan] && [dict get $state trials] < $::env(MAX_VT_TRIALS)} {incr start $width} {
        if {$refresh > 0 && $start > 0 && ($start/$width)%$refresh == 0} {
            set remaining [expr {$::env(MAX_BATCH_CELLS)-$start}]
            set suffix [batch_plan $block $replacements $protected $baseline $attempted $remaining]
            set plan [concat [lrange $plan 0 [expr {$start-1}]] $suffix]
        }
        set batch [lrange $plan $start [expr {$start+$width-1}]]
        foreach item $batch { dict set attempted [lindex $item 0] 1 }
        try_batch $block $batch $baseline $report state
    }
    return [list [dict get $state trials] [dict get $state changed] [dict get $state score]]
}

# Add delay at hold-violating sinks with setup slack or WNS headroom in every scene.
# Freeze existing cells during legalization so clock/sink and logic locations stay fixed.
proc optimizer::repair_short_paths {block} {
    set candidates [dict create]
    set sink_slacks [dict create]
    set residual_tns [dict create]
    foreach scene {BC TC WC} {
        dict set residual_tns $scene [expr {max(0.0,-[sta::total_negative_slack -scene $scene -min])}]
        foreach path [find_timing_paths -scenes $scene -path_delay min \
            -group_path_count 10000 -endpoint_path_count 1 -slack_max -1] {
            set pin [get_property $path endpoint]
            set name [get_full_name $pin]
            set slack [get_property $path slack]
            dict set sink_slacks $name $scene $slack
            if {![dict exists $candidates $name] || $slack < [lindex [dict get $candidates $name] 0]} {
                dict set candidates $name [list $slack $pin]
            }
        }
    }
    # Snapshot setup slacks without re-resolving bus names as glob patterns.
    set margins [dict create]
    set gaps [dict create]
    foreach scene {BC TC WC} {
        set worst [sta::worst_slack -scene $scene -max]
        foreach path [find_timing_paths -scenes $scene -path_delay max \
            -group_path_count 1000000 -endpoint_path_count 1 -slack_max 1e30] {
            set name [get_full_name [get_property $path endpoint]]
            set slack [get_property $path slack]
            set gap [expr {$slack-$worst}]
            if {![dict exists $gaps $name] || $gap < [dict get $gaps $name]} { dict set gaps $name $gap }
            if {![dict exists $margins $name] || $slack < [dict get $margins $name]} {
                dict set margins $name $slack
            }
        }
    }
    set needs_tns_repair 0
    dict for {scene magnitude} $residual_tns { if {$magnitude > 900.0} { set needs_tns_repair 1 } }
    set audit [open [file join [file dirname $::env(OUTPUT_DEF)] hold_candidates.tsv] w]
    puts $audit "sink\thold_slack_ps\tsetup_margin_ps\tsetup_gap_ps"
    set ranked {}
    dict for {name data} $candidates {
        lassign $data hold_slack pin
        set cells [get_cells -quiet -of_objects $pin]
        if {[llength $cells] != 1 || ![dict exists $margins $name]} { continue }
        set inst [sta::sta_to_db_inst [lindex $cells 0]]
        if {$inst eq "NULL" || [$inst isDoNotTouch]} { continue }
        set margin [dict get $margins $name]
        set gap [dict get $gaps $name]
        puts $audit "$name\t$hold_slack\t$margin\t$gap"
        if {$margin >= 40.0 || (($hold_slack < -10.0 || $needs_tns_repair) && $gap >= 40.0)} {
            set iterm [$inst findITerm [get_property $pin lib_pin_name]]
            if {$iterm ne "NULL"} { lappend ranked [list $hold_slack $name $margin $inst $iterm] }
        }
    }
    close $audit
    set ranked [lsort -real -index 0 [lsort -ascii -index 1 $ranked]]
    set count 0
    set inserted [dict create]
    set master [[ord::get_db] findMaster BUFx2_ASAP7_75t_R]
    if {$master eq "NULL"} { error "Hold buffer master is unavailable" }
    set report [open [file join [file dirname $::env(OUTPUT_DEF)] hold_buffers.tsv] w]
    try {
        puts $report "instance\tsink\thold_slack_ps\tsetup_margin_ps"
        foreach row $ranked {
            if {$count >= $::env(MAX_HOLD_BUFFERS)} { break }
            lassign $row slack sink margin inst iterm
            set needs_tns_repair 0
            dict for {scene magnitude} $residual_tns { if {$magnitude > 900.0} { set needs_tns_repair 1 } }
            if {$slack >= -10.0 && !$needs_tns_repair} { break }
            set name "mcmm_hold_$count"
            # Avoid colliding with benchmark instance names.
            while {[$block findInst $name] ne "NULL"} { append name _ }
            set old_net [$iterm getNet]
            if {$old_net eq "NULL" || [$old_net getSigType] ne "SIGNAL"} { continue }
            set net_name ${name}_net
            while {[$block findNet $net_name] ne "NULL"} { append net_name _ }
            set buffer [odb::dbInst_create $block $master $name]
            set net [odb::dbNet_create $block $net_name]
            $net setSigType SIGNAL
            [$buffer findITerm A] connect $old_net
            [$buffer findITerm Y] connect $net
            $iterm disconnect
            $iterm connect $net
            lassign [$inst getLocation] x y
            $buffer setLocation $x $y
            $buffer setPlacementStatus PLACED
            dict set inserted $name 1
            puts $report "$name\t$sink\t$slack\t$margin"
            incr count
            # One buffer is expected to eliminate this sink's short-path deficit.
            # A 100 ps reserve below the 1 ns tolerance absorbs estimation error.
            dict for {scene old_slack} [dict get $sink_slacks $sink] {
                dict set residual_tns $scene [expr {max(0.0,[dict get $residual_tns $scene]+$old_slack)}]
            }
        }
    } finally {
        close $report
        set_scene TC
    }
    if {$count > 0} {
        set statuses [dict create]
        foreach inst [$block getInsts] {
            if {[dict exists $inserted [$inst getName]]} { continue }
            dict set statuses [$inst getName] [$inst getPlacementStatus]
            if {[$inst getPlacementStatus] eq "PLACED"} { $inst setPlacementStatus FIRM }
        }
        try {
            detailed_placement
        } finally {
            dict for {name status} $statuses { [$block findInst $name] setPlacementStatus $status }
        }
    }
    puts "Hold repair inserted $count buffers; predicted residual hold TNS (ps): $residual_tns"
    return $count
}

proc optimizer::physical_only {} {
    set result {}
    foreach lib [[ord::get_db] getLibs] {
        foreach cell [$lib getMasters] {
            set signal 0
            foreach pin [$cell getMTerms] {
                if {[$pin getSigType] ni {POWER GROUND}} {
                    set signal 1
                    break
                }
            }
            if {!$signal} {
                lappend result [$cell getName]
            }
        }
    }
    return $result
}

proc optimizer::run {} {
    set block [load_design]
    set replacements [replacement_masters]
    set protected [protected_instances $block]
    initialize_timing
    puts "MCMM routing complete; collecting baseline timing."
    flush stdout
    # Small incremental timing updates avoid worker scheduling overhead.
    set_thread_count 1
    set baseline [timing_metrics]
    set best_metrics $baseline
    set best_score [objective $baseline $baseline]
    puts "Baseline timing: $baseline"
    flush stdout
    set max_trials $::env(MAX_VT_TRIALS)
    set trials 0
    set changed 0
    set report [open [file join [file dirname $::env(OUTPUT_DEF)] swaps.tsv] w]
    try {
        puts $report "instance\told_master\tnew_master\tobjective"
        fconfigure $report -buffering line
        if {$::env(VT_STRATEGY) eq "batch"} {
            lassign [batch_search $block $replacements $protected $baseline $report] trials changed best_score
        } else {
            # Refresh critical-path ranking between passes as bottlenecks change.
            for {set pass 0} {$pass < 2 && $trials < $max_trials} {incr pass} {
                set accepted 0
                set candidates [rank_candidates $block $replacements $protected $baseline]
                puts "VT pass $pass: [llength $candidates] candidate instances"
                flush stdout
                foreach candidate $candidates {
                    if {$trials >= $max_trials} { break }
                    lassign $candidate weight name
                    set inst [$block findInst $name]
                    set original [$inst getMaster]
                    set chosen $original
                    set local_score $best_score
                    set local_metrics $best_metrics
                    foreach target [dict get $replacements [$original getName]] {
                        if {$trials >= $max_trials} { break }
                        if {![$inst swapMaster $target]} { error "Master swap failed for $name" }
                        incr trials
                        if {$trials % 25 == 0} { puts "VT trial $trials: accepted=$changed objective=$best_score"; flush stdout }
                        set metrics [timing_metrics]
                        set score [objective $metrics $baseline]
                        # Reject cumulative deterioration in each corner's hold WNS.
                        set safe 1
                        foreach scene {BC TC WC} {
                            if {[lindex [dict get $metrics $scene] 2] < [lindex [dict get $baseline $scene] 2]-0.2} { set safe 0 }
                        }
                        if {$safe && $score > $local_score+0.00001} {
                            set chosen $target
                            set local_score $score
                            set local_metrics $metrics
                        }
                        if {![$inst swapMaster $original]} { error "Master restore failed for $name" }
                    }
                    if {$chosen ne $original} {
                        if {![$inst swapMaster $chosen]} { error "Accepted master swap failed for $name" }
                        set best_score $local_score
                        set best_metrics $local_metrics
                        incr changed
                        incr accepted
                        puts $report "$name\t[$original getName]\t[$chosen getName]\t$best_score"
                    }
                    if {$trials % 50 == 0} { puts "VT search: trials=$trials accepted=$changed objective=$best_score"; flush stdout }
                }
                puts "VT pass $pass: accepted=$accepted trials=$trials objective=$best_score"
                if {$accepted == 0} { break }
            }
        }
    } finally {
        close $report
    }
    set_thread_count $::env(NUM_CORES)
    set buffers [repair_short_paths $block]
    if {$changed == 0 && $buffers == 0} { error "Timing search found no improving legal changes" }
    set fp [open [file join [file dirname $::env(OUTPUT_DEF)] timing_search.json] w]
    puts $fp [format {{"trials":%d,"accepted_moves":%d,"initial_objective":%.9f,"vt_objective":%.9f}} \
        $trials $changed [objective $baseline $baseline] $best_score]
    close $fp
    check_placement -verbose
    # global_route creates a grid that must not leak into the submitted DEF.
    variable grid_patterns
    set grid [$block getGCellGrid]
    $grid resetGrid
    foreach axis {X Y} {
        foreach pattern [dict get $grid_patterns $axis] { $grid addGridPattern$axis {*}$pattern }
    }
    write_def $::env(OUTPUT_DEF)
    write_verilog -remove_cells [physical_only] $::env(OUTPUT_VERILOG)
    puts "Timing-driven search accepted $changed swaps in $trials trials."
}

optimizer::run
