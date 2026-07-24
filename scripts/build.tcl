set script_dir [file dirname [file normalize [info script]]]
set project_dir [file dirname $script_dir]
set project_file [file join $project_dir tang_nano_20k_sdcard.gprj]

puts "Opening project: $project_file"
open_project $project_file
set_option -top_module top
set_option -synthesis_tool gowinsynthesis
set_option -output_base_name tang_nano_20k_sdcard
run all
