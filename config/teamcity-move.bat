
%map_drive%

p:\1002266-xbeach\teamcity\plink.exe xbeach@p-h5devux -pw xb3@ch123 -batch "cp -r -f /p/1002266-xbeach/teamcity/temp_build_dir/trunk /opt/xbeach/trunk_gcc_4.9.1_1.8.1_HEAD/ && chmod 775 /opt/xbeach/trunk_gcc_4.9.1_1.8.1_HEAD/"

%unmap_drive%