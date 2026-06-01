# update sources heirarchy
update_compile_order -force_gui -fileset sources_1
# Reset and rebuild from scratch
reset_runs impl_1
reset_runs synth_1
launch_runs synth_1
wait_on_run synth_1
open_run synth_1
report_timing_summary -file reports/timing.rpt
report_utilization -file reports/utilization.rpt
