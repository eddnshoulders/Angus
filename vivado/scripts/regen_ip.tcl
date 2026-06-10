upgrade_ip [get_ips]
reset_target all [get_files pynq_z2.bd]
export_ip_user_files -of_objects [get_files pynq_z2.bd] -no_script -sync -force -quiet
generate_target all [get_files pynq_z2.bd] -force
update_compile_order -fileset sources_1