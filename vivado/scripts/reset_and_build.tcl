# update sources heirarchy
update_compile_order -force_gui -fileset sources_1
# update HDL module reference top_0
update_module_reference pynq_z2_top_0_0

# get the director of this script
set script_dir [file dirname [file normalize [info script]]]

# reset previous runs to force full rebuild
reset_runs synth_1
reset_runs impl_1

# run synthesise
launch_runs synth_1 -jobs 16
wait_on_run synth_1

# run implementation
launch_runs impl_1 -jobs 16 -to_step write_bitstream
wait_on_run impl_1

# create reports
open_run impl_1
report_timing_summary -file $script_dir/../reports/timing.rpt
report_utilization -file $script_dir/../reports/utilization.rpt

#report_timing_summary -file timing.rpt
#report_utilization -file utilization.rpt