#!/bin/bash
function build_wheel {
    echo Done building wheel
}

function run_tests {
    cd ..
    pip install --no-deps --index-url https://test.pypi.org/simple/ onnx==1.3.0
    local wkdir_path="$(pwd)"
    echo Running tests at root path: ${wkdir_path}
    cd ${wkdir_path}/onnx
    pip install tornado==4.5.3
    pip install pytest-cov nbval
    pytest
}