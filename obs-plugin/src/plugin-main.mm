#include <obs-module.h>

OBS_DECLARE_MODULE()
OBS_MODULE_AUTHOR("iPhoneCam")

extern obs_source_info iphonecam_source_info;

bool obs_module_load(void)
{
    obs_register_source(&iphonecam_source_info);
    return true;
}

const char *obs_module_name(void)
{
    return "iPhoneCam OBS";
}

const char *obs_module_description(void)
{
    return "Receives iPhoneCam video as an OBS input source.";
}
