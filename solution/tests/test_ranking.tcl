# Run with tclsh solution/tests/test_ranking.tcl (no design or OpenROAD needed).
set fp [open [file join [file dirname [info script]] .. optimizer.tcl] r]
set code [read $fp]
close $fp
if {![regsub {optimizer::run\s*$} $code {} code]} { error "Cannot isolate optimizer procedures" }
eval $code
namespace eval sta {}
proc sta::sta_to_db_inst {cell} { return $cell }
set ::env(VT_PATH_COUNT) 500
proc find_timing_paths {args} {
    if {[lindex $args [expr {[lsearch -exact $args -path_delay]+1}]] ne "max"} {
        error "Faster-cell ranking must not reward hold paths"
    }
    return path
}
proc get_property {object property} {
    if {$object eq "path"} {
        switch -- $property {
            slack { return -100.0 }
            points { return {a_in a_out b_in b_out} }
        }
    }
    switch -- $property {
        pin { return $object }
        lib_pin_name { return [expr {[string match *_out $object] ? "Y" : "A"}] }
        arrival { return [dict get {a_in 1000.0 a_out 1005.0 b_in 1006.0 b_out 1026.0} $object] }
    }
    error "Unexpected property $object/$property"
}
proc get_cells {args} {
    return [expr {[string match a_* [lindex $args end]] ? "inst_a" : "inst_b"}]
}
proc test_instance {name method args} {
    switch -- $method {
        getName { return $name }
        getMaster { return master }
        findITerm { return output_term }
    }
    error "Unexpected instance operation $method"
}
interp alias {} inst_a {} test_instance a
interp alias {} inst_b {} test_instance b
proc master {method} { return allowed_master }
proc output_term {method} { return output_mterm }
proc output_mterm {method} { return OUTPUT }
set baseline [dict create BC {-100 0 0 0} TC {-100 0 0 0} WC {-100 0 0 0}]
set replacements [dict create allowed_master target]
set ranked [optimizer::sensitivity_candidates unused $replacements {} $baseline]
if {[llength $ranked] != 2 || [lindex $ranked 0 1] ne "b"} {
    error "Cell delay must outrank large upstream wire/clock arrival: $ranked"
}
set ranked [optimizer::sensitivity_candidates unused $replacements {b 1} $baseline]
if {[llength $ranked] != 1 || [lindex $ranked 0 1] ne "a"} {
    error "Protected instances must be excluded: $ranked"
}
puts "PASS: cell-arc sensitivity excludes wire delay, hold paths, and protected cells"
