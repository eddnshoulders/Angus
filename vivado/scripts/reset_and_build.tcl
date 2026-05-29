# Reset and rebuild from scratch
reset_runs impl_1
reset_runs synth_1
launch_runs synth_1
wait_on_run synth_1
launch_runs impl_1 -to_step write_bitstream
wait_on_run impl_1
open_run impl_1
report_timing_summary -file reports/timing.rpt
report_utilization -file reports/utilization.rpt