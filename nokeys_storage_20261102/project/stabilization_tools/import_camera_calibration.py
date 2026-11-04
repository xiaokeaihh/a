"""Import original camera HDMI PNG calibration into the existing DDR geometry.

Usage: python stabilization_tools/import_camera_calibration.py camera_parameters.json
The camera RAW HDMI output is a 180-degree display rotation of canonical DDR.
"""
from pathlib import Path
from datetime import datetime, timezone
import json
import shutil
import sys
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT/'source/design_fisheye_5frame_720p60_pipeline/data'

def main():
    source = Path(sys.argv[1]).resolve()
    params = json.loads(source.read_text(encoding='utf-8'))
    assert params['model'] == 'opencv_fisheye'
    assert params['image_size_wh'] == [1280, 720]
    assert params['distortion_coefficient_order'] == ['k1', 'k2', 'k3', 'k4']
    original = np.array(params['K'], dtype=np.float64)
    d = np.array(params['D'], dtype=np.float64)
    assert np.isfinite(original).all() and np.isfinite(d).all() and len(d) == 4
    native = original.copy()
    native[0, 2] = 1279-original[0, 2]
    native[1, 2] = 719-original[1, 2]
    cfg = json.loads((DATA/'baseline_config.json').read_text(encoding='utf-8'))
    cfg.update(source_K=native.tolist(), source_D=d.tolist(), camera_K_D_changed=True,
        calibration_id=params['calibration_id'], source_orientation='canonical camera DDR; 180-degree rotation from calibration PNG',
        calibration_raw_K=original.tolist(),
        calibration_to_source_coordinates=dict(u='1279-u_png', v='719-v_png'),
        HDMI_orientation='camera: 180-degree display rotation; external HDMI input: ordinary top-left')
    # Keep the established horizontal FOV and output resolution, updating pixel aspect.
    cfg['output_K'][1][1] = cfg['output_K'][0][0]*native[1,1]/native[0,0]
    (DATA/'baseline_config.json').write_text(json.dumps(cfg, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    report = dict(created_at=datetime.now(timezone.utc).isoformat(), opencv_version=params['fitting']['version'],
        model='OpenCV fisheye; k1,k2,k3,k4 optimized', calibration_id=params['calibration_id'],
        image_dir=params['provenance']['source_image_directory'], image_size_width_height=[1280,720],
        capture_size_width_height=[1280,720], capture_to_native_coordinate_scale=1.0,
        inner_corners_cols_rows=[11,8], adjacent_corner_distance_mm=6.0,
        files_found=params['fitting']['input_image_count'], images_detected=params['fitting']['detected_image_count'],
        images_used=params['fitting']['selected_image_count'], outlier_threshold_px=0.25,
        threshold_comparison='strictly less than', reprojection_error_units='native 1280x720 pixels',
        calibration=dict(K=native.tolist(), D=d.tolist(), fx_px=native[0,0], fy_px=native[1,1],
            cx_px=native[0,2], cy_px=native[1,2], k1=d[0], k2=d[1], k3=d[2], k4=d[3],
            opencv_rms_px=params['fitting']['global_rms_px'], reprojection_rms_px=params['fitting']['global_rms_px']),
        raw_png_calibration=dict(K=original.tolist(), D=d.tolist(),
            transform_to_camera_DDR='u_ddr=1279-u_png; v_ddr=719-v_png; radial coefficients unchanged'),
        per_image=[dict(file=x['file'], reprojection_rms_px=x['rms_px']) for x in params['selected_views']],
        image_audit=params['image_audit'], quality_warning='Selected training error; not independent full-field validation')
    (DATA/'calibration_720p.json').write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    shutil.copy2(source, DATA/'camera_parameters_20261028.json')
    # Frozen view positions and FOVs remain authoritative; old quality figures are historical.
    views_path = DATA/'balanced_config.json'
    views = json.loads(views_path.read_text(encoding='utf-8'))
    views['camera_K_D_changed'] = True
    views['calibration_id'] = params['calibration_id']
    views['stored_quality_metrics_note'] = 'Inherited metrics describe the previous calibration; view configs are preserved'
    views_path.write_text(json.dumps(views, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    print(json.dumps(dict(calibration_id=params['calibration_id'], raw_K=original.tolist(), DDR_K=native.tolist(), D=d.tolist()), indent=2))

if __name__ == '__main__':
    main()
