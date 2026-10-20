import Foundation

/// Maps `pipeline_id` to vendored `imagegen_plugins/pipelines/*.py` worker scripts.
enum ImageGenPipelineCatalog {
    private static let workerScripts: [String: String] = [
        "flux_schnell_mflux_play": "mflux_schnell.py",
        "sana_sprint_600m": "sana_sprint.py",
        "z_image_turbo_sdnq": "z_image_turbo.py",
        "mflux_z_image_turbo": "mflux_z_image_turbo.py",
        "sd15_diffusers": "sd15_diffusers.py",
        "sdxl_diffusers": "sdxl_diffusers.py",
        "mflux_fill_expand": "mflux_fill_expand.py",
        "mflux_fill_infill": "mflux_fill_expand.py",
        "mflux_flux2_klein_create": "mflux_flux2_klein_create.py",
        "mflux_flux2_klein_edit": "mflux_flux2_klein_edit.py",
        "mflux_flux2_klein_expand": "mflux_flux2_klein_edit.py",
    ]

    static func workerScriptName(pipelineID: String) -> String? {
        workerScripts[pipelineID]
    }

    static func hasWorkerScript(pipelineID: String) -> Bool {
        workerScriptName(pipelineID: pipelineID) != nil
    }
}
