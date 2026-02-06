#!/bin/bash
set -e

# Parse arguments
HELP=false
NEW_ENV=false
OMNIGIBSON=false
BDDL=false
JOYLO=false
DATASET=false
PRIMITIVES=false
EVAL=false
ASSET_PIPELINE=false
DEV=false
# Default CUDA wheel index (good default for Blackwell driver stacks today)
CUDA_VERSION="12.8"

# Default PyTorch versions (used when eval / lerobot are not requested)
PYTORCH_VERSION_DEFAULT="2.9.1"
TORCHVISION_VERSION_DEFAULT="0.24.1"
TORCHAUDIO_VERSION_DEFAULT="2.9.1"

# lerobot currently requires torch<2.8 and torchvision<0.23
PYTORCH_VERSION_LEROBOT="2.7.1"
TORCHVISION_VERSION_LEROBOT="0.22.1"
TORCHAUDIO_VERSION_LEROBOT="2.7.1"

# Selected versions (set by select_pytorch_versions)
PYTORCH_VERSION=""
TORCHVISION_VERSION=""
TORCHAUDIO_VERSION=""

# Disable pip and CUDA compute caches (user request for Blackwell)
export PIP_NO_CACHE_DIR=1
export CUDA_CACHE_DISABLE=1
ACCEPT_CONDA_TOS=false
ACCEPT_NVIDIA_EULA=false
ACCEPT_DATASET_TOS=false
CONFIRM_NO_CONDA=false
HF_CACHE_DIR=""
CLEAR_HF_CACHE=false

[ "$#" -eq 0 ] && HELP=true

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help) HELP=true; shift ;;
        --new-env) NEW_ENV=true; shift ;;
        --omnigibson) OMNIGIBSON=true; shift ;;
        --bddl) BDDL=true; shift ;;
        --joylo) JOYLO=true; shift ;;
        --dataset) DATASET=true; shift ;;
        --primitives) PRIMITIVES=true; shift ;;
        --eval) EVAL=true; shift ;;
        --asset-pipeline) ASSET_PIPELINE=true; shift ;;
        --dev) DEV=true; shift ;;
        --cuda-version) CUDA_VERSION="$2"; shift 2 ;;
        --accept-conda-tos) ACCEPT_CONDA_TOS=true; shift ;;
        --accept-nvidia-eula) ACCEPT_NVIDIA_EULA=true; shift ;;
        --accept-dataset-tos) ACCEPT_DATASET_TOS=true; shift ;;
        --confirm-no-conda) CONFIRM_NO_CONDA=true; shift ;;
        --hf-cache-dir) HF_CACHE_DIR="$2"; shift 2 ;;
        --clear-hf-cache) CLEAR_HF_CACHE=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ "$HELP" = true ]; then
    cat << EOF
BEHAVIOR-1K Installation Script (Linux)
Usage: ./setup.sh [OPTIONS]

Options:
  -h, --help              Display this help message
  --new-env               Create a new conda environment 'behavior'
  --omnigibson            Install OmniGibson (core physics simulator)
  --bddl                  Install BDDL (Behavior Domain Definition Language)
  --joylo                 Install JoyLo (teleoperation interface)
  --dataset               Download BEHAVIOR datasets (requires --omnigibson)
  --primitives            Install OmniGibson with primitives support
  --eval                  Install evaluation dependencies
  --asset-pipeline        Install the 3D scene and object asset pipeline
  --dev                   Install development dependencies
  --cuda-version VERSION  Specify CUDA version (default: 12.8)
  --accept-conda-tos      Automatically accept Conda Terms of Service
  --accept-nvidia-eula    Automatically accept NVIDIA Isaac Sim EULA
  --accept-dataset-tos    Automatically accept BEHAVIOR Dataset Terms
  --confirm-no-conda      Skip confirmation prompt when not in a conda environment
  --hf-cache-dir DIR      Set HuggingFace cache dir (HF_HOME) for dataset downloads
  --clear-hf-cache        Remove HuggingFace caches before downloading datasets

Example: ./setup.sh --new-env --omnigibson --bddl --joylo --dataset
Example (non-interactive): ./setup.sh --new-env --omnigibson --dataset --accept-conda-tos --accept-nvidia-eula --accept-dataset-tos
EOF
    exit 0
fi

# Validate dependencies
[ "$OMNIGIBSON" = true ] && [ "$BDDL" = false ] && { echo "ERROR: --omnigibson requires --bddl"; exit 1; }
[ "$PRIMITIVES" = true ] && [ "$OMNIGIBSON" = false ] && { echo "ERROR: --primitives requires --omnigibson"; exit 1; }
[ "$EVAL" = true ] && [ "$OMNIGIBSON" = false ] && { echo "ERROR: --eval requires --omnigibson"; exit 1; }
[ "$EVAL" = true ] && [ "$JOYLO" = false ] && { echo "ERROR: --eval requires --joylo"; exit 1; }
[ "$NEW_ENV" = true ] && [ "$CONFIRM_NO_CONDA" = true ] && { echo "ERROR: --new-env and --confirm-no-conda are mutually exclusive"; exit 1; }

WORKDIR=$(pwd)

normalize_cuda_for_pytorch() {
    local requested="$1"
    case "$requested" in
        13.1|13.0|13) echo "13.0" ;;
        12.8) echo "12.8" ;;
        12.4) echo "12.4" ;;
        *) return 1 ;;
    esac
}

SETUP_CONSTRAINTS_FILE="$(mktemp -t behavior-setup-constraints-XXXXXX.txt)"
trap 'rm -f "$SETUP_CONSTRAINTS_FILE"' EXIT
cat >"$SETUP_CONSTRAINTS_FILE" << 'EOF'
numpy<2
setuptools<=79
EOF
export PIP_CONSTRAINT="$SETUP_CONSTRAINTS_FILE"

has_python_module() {
    local module_name="$1"
    python - << PY >/dev/null 2>&1
import importlib.util
import sys
sys.exit(0 if importlib.util.find_spec("${module_name}") is not None else 1)
PY
}

select_pytorch_versions() {
    # If eval is enabled (installs lerobot) or lerobot already exists in the current env,
    # select a torch/torchvision/torchaudio trio that satisfies lerobot constraints.
    if [ "$EVAL" = true ] || { [ "$NEW_ENV" = false ] && has_python_module "lerobot"; }; then
        PYTORCH_VERSION="$PYTORCH_VERSION_LEROBOT"
        TORCHVISION_VERSION="$TORCHVISION_VERSION_LEROBOT"
        TORCHAUDIO_VERSION="$TORCHAUDIO_VERSION_LEROBOT"
    else
        PYTORCH_VERSION="$PYTORCH_VERSION_DEFAULT"
        TORCHVISION_VERSION="$TORCHVISION_VERSION_DEFAULT"
        TORCHAUDIO_VERSION="$TORCHAUDIO_VERSION_DEFAULT"
    fi
}

install_pytorch_wheels() {
    local cuda_ver_short="$1"
    local index_url="https://download.pytorch.org/whl/cu${cuda_ver_short}"

    echo "Installing PyTorch (torch==$PYTORCH_VERSION, torchvision==$TORCHVISION_VERSION, torchaudio==$TORCHAUDIO_VERSION) from $index_url"
    pip install \
      "torch==${PYTORCH_VERSION}" "torchvision==${TORCHVISION_VERSION}" "torchaudio==${TORCHAUDIO_VERSION}" \
      --index-url "$index_url"
}

ensure_pytorch_trio() {
    local pytorch_cuda="$1"
    local cuda_ver_short
    cuda_ver_short=$(echo "$pytorch_cuda" | sed 's/\.//g')

    set +e
    python - << PY >/dev/null 2>&1
import sys
def get(name):
    try:
        m = __import__(name)
        return getattr(m, "__version__", "")
    except Exception:
        return ""

torch_v = get("torch").split("+")[0]
tv_v = get("torchvision").split("+")[0]
ta_v = get("torchaudio").split("+")[0]

ok = (torch_v == "${PYTORCH_VERSION}" and tv_v == "${TORCHVISION_VERSION}" and ta_v == "${TORCHAUDIO_VERSION}")
sys.exit(0 if ok else 1)
PY
    local versions_ok=$?
    set -e

    TORCH_CUDA_VER=$(python -c "import torch; print(torch.version.cuda or '')" 2>/dev/null || true)
    local cuda_ok=true
    if [ -n "$TORCH_CUDA_VER" ] && [ "$TORCH_CUDA_VER" != "$pytorch_cuda" ]; then
        cuda_ok=false
    fi

    if [ "$versions_ok" -eq 0 ] && [ "$cuda_ok" = true ]; then
        return 0
    fi

    echo "Aligning PyTorch stack for this environment..."
    pip uninstall -y torch torchvision torchaudio >/dev/null 2>&1 || true

    set +e
    install_pytorch_wheels "$cuda_ver_short"
    local install_status=$?
    set -e
    if [ "$install_status" -ne 0 ] && [ "$cuda_ver_short" = "130" ]; then
        echo "WARNING: Failed to install cu130 wheels; falling back to cu128."
        install_pytorch_wheels "128"
    elif [ "$install_status" -ne 0 ]; then
        exit "$install_status"
    fi
}

detect_cuda_toolkit_paths() {
    # Echo "<nvcc_real>|<include_dir>|<lib_dir>" or return non-zero.
    # This is used to build curobo (CUDA extension) when primitives are enabled.
    local nvcc_real

    if [ -n "${NVCC:-}" ] && [ -x "${NVCC:-}" ]; then
        nvcc_real="$NVCC"
    else
        nvcc_real=$(command -v nvcc 2>/dev/null || true)
    fi
    [ -n "$nvcc_real" ] || return 1

    if command -v readlink >/dev/null 2>&1; then
        nvcc_real=$(readlink -f "$nvcc_real" 2>/dev/null || echo "$nvcc_real")
    fi

    local cuda_root
    cuda_root=$(dirname "$(dirname "$nvcc_real")")

    local include_dir=""
    local lib_dir=""

    # Common CUDA layouts (system + conda).
    if [ -f "$cuda_root/include/cuda_runtime.h" ]; then
        include_dir="$cuda_root/include"
    elif [ -f "$cuda_root/targets/x86_64-linux/include/cuda_runtime.h" ]; then
        include_dir="$cuda_root/targets/x86_64-linux/include"
    else
        local tdir
        tdir=$(ls -d "$cuda_root"/targets/*/include 2>/dev/null | head -n 1 || true)
        if [ -n "$tdir" ] && [ -f "$tdir/cuda_runtime.h" ]; then
            include_dir="$tdir"
        fi
    fi

    if [ -d "$cuda_root/lib64" ]; then
        lib_dir="$cuda_root/lib64"
    elif [ -d "$cuda_root/lib" ]; then
        lib_dir="$cuda_root/lib"
    elif [ -d "$cuda_root/targets/x86_64-linux/lib" ]; then
        lib_dir="$cuda_root/targets/x86_64-linux/lib"
    else
        local ldir
        ldir=$(ls -d "$cuda_root"/targets/*/lib 2>/dev/null | head -n 1 || true)
        if [ -n "$ldir" ]; then
            lib_dir="$ldir"
        fi
    fi

    [ -n "$include_dir" ] || return 2
    [ -n "$lib_dir" ] || return 3
    echo "${nvcc_real}|${include_dir}|${lib_dir}"
    return 0
}

df_free_bytes() {
    local target_path="$1"
    local kb
    kb=$(df -Pk "$target_path" 2>/dev/null | awk 'NR==2 {print $4}' || true)
    if [ -z "$kb" ]; then
        echo "0"
        return 0
    fi
    echo $((kb * 1024))
}

setup_hf_cache() {
    local default_cache="${XDG_CACHE_HOME:-$HOME/.cache}/huggingface"
    local workdir_cache="$WORKDIR/.hf-cache"

    # Determine cache location if not explicitly set.
    if [ -z "$HF_CACHE_DIR" ]; then
        # Heuristic: if the default cache filesystem is low on space, use workspace-local cache instead.
        # Downloads can be large (e.g., 30+ GB zip), and unpacking may require additional space.
        local required_bytes=$((60 * 1024 * 1024 * 1024)) # 60GB
        local default_free
        default_free=$(df_free_bytes "$(dirname "$default_cache")")
        if [ "$default_free" -lt "$required_bytes" ]; then
            HF_CACHE_DIR="$workdir_cache"
            echo "Low free space on default cache filesystem; using HF cache in: $HF_CACHE_DIR"
        else
            HF_CACHE_DIR="$default_cache"
        fi
    fi

    if [ "$CLEAR_HF_CACHE" = true ]; then
        echo "Clearing HuggingFace cache(s)..."
        if [ -n "$HF_CACHE_DIR" ]; then
            rm -rf "$HF_CACHE_DIR" || true
        else
            rm -rf "$default_cache" "$workdir_cache" || true
        fi
    fi

    mkdir -p "$HF_CACHE_DIR"

    # HuggingFace Hub cache variables
    export HF_HOME="$HF_CACHE_DIR"
    export HUGGINGFACE_HUB_CACHE="$HF_CACHE_DIR/hub"
    export HF_HUB_CACHE="$HF_CACHE_DIR/hub"
    export HF_ASSETS_CACHE="$HF_CACHE_DIR/assets"
    export HF_DATASETS_CACHE="$HF_CACHE_DIR/datasets"

    # Be more tolerant of transient network issues.
    export HF_HUB_ETAG_TIMEOUT="${HF_HUB_ETAG_TIMEOUT:-60}"
    export HF_HUB_DOWNLOAD_TIMEOUT="${HF_HUB_DOWNLOAD_TIMEOUT:-600}"

    if [ -z "${HF_TOKEN:-}" ] && [ -z "${HUGGINGFACE_HUB_TOKEN:-}" ]; then
        echo "Note: Set HF_TOKEN to avoid HuggingFace rate limits (optional)."
    fi
}

# Check conda environment condition early (unless creating new environment)
if [ "$NEW_ENV" = false ]; then
    if [ -z "$CONDA_PREFIX" ]; then
        if [ "$CONFIRM_NO_CONDA" = false ]; then
            echo ""
            echo "WARNING: You are not in a conda environment."
            echo "Currently using Python from: $(which python)"
            echo ""
            echo "Continue? [y/n] (or rerun with --confirm-no-conda to skip this prompt)"
            read -r response
            if [[ ! "$response" =~ ^[Yy]$ ]]; then
                echo "Installation cancelled."
                exit 1
            fi
        fi
        echo "Proceeding without conda environment..."
    fi
fi

# Function to prompt for terms acceptance
prompt_for_terms() {
    echo ""
    echo "=== TERMS OF SERVICE AND LICENSING AGREEMENTS ==="
    echo ""
    
    # Check what terms need to be accepted
    NEEDS_CONDA_TOS=false
    NEEDS_NVIDIA_EULA=false
    NEEDS_DATASET_TOS=false
    
    if [ "$NEW_ENV" = true ] && [ "$ACCEPT_CONDA_TOS" = false ]; then
        NEEDS_CONDA_TOS=true
    fi
    
    if [ "$OMNIGIBSON" = true ] && [ "$ACCEPT_NVIDIA_EULA" = false ]; then
        NEEDS_NVIDIA_EULA=true
    fi
    
    if [ "$DATASET" = true ] && [ "$ACCEPT_DATASET_TOS" = false ]; then
        NEEDS_DATASET_TOS=true
    fi
    
    # If nothing needs acceptance, return early
    if [ "$NEEDS_CONDA_TOS" = false ] && [ "$NEEDS_NVIDIA_EULA" = false ] && [ "$NEEDS_DATASET_TOS" = false ]; then
        return 0
    fi
    
    echo "This installation requires acceptance of the following terms:"
    echo ""
    
    if [ "$NEEDS_CONDA_TOS" = true ]; then
        cat << EOF
1. CONDA TERMS OF SERVICE
   - Required for creating conda environment
   - By accepting, you agree to Anaconda's Terms of Service
   - See: https://legal.anaconda.com/policies/en/

EOF
    fi
    
    if [ "$NEEDS_NVIDIA_EULA" = true ]; then
        cat << EOF
2. NVIDIA ISAAC SIM EULA
   - Required for OmniGibson installation
   - By accepting, you agree to NVIDIA Isaac Sim End User License Agreement
   - See: https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-software-license-agreement

EOF
    fi
    
    if [ "$NEEDS_DATASET_TOS" = true ]; then
        cat << EOF
3. BEHAVIOR DATA BUNDLE END USER LICENSE AGREEMENT
    Last revision: December 8, 2022
    This License Agreement is for the BEHAVIOR Data Bundle (“Data”). It works with OmniGibson (“Software”) which is a software stack licensed under the MIT License, provided in this repository: https://github.com/StanfordVL/BEHAVIOR-1K. 
    The license agreements for OmniGibson and the Data are independent. This BEHAVIOR Data Bundle contains artwork and images (“Third Party Content”) from third parties with restrictions on redistribution. 
    It requires measures to protect the Third Party Content which we have taken such as encryption and the inclusion of restrictions on any reverse engineering and use. 
    Recipient is granted the right to use the Data under the following terms and conditions of this License Agreement (“Agreement”):
        1. Use of the Data is permitted after responding "Yes" to this agreement. A decryption key will be installed automatically.
        2. Data may only be used for non-commercial academic research. You may not use a Data for any other purpose.
        3. The Data has been encrypted. You are strictly prohibited from extracting any Data from OmniGibson or reverse engineering.
        4. You may only use the Data within OmniGibson.
        5. You may not redistribute the key or any other Data or elements in whole or part.
        6. THE DATA AND SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. 
            IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE DATA OR SOFTWARE OR THE USE OR OTHER DEALINGS IN THE DATA OR SOFTWARE.

EOF
    fi
    
    echo "Do you accept ALL of the above terms? (y/N)"
    read -r response
    
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        echo "Terms not accepted. Installation cancelled."
        echo "You can bypass these prompts by using --accept-conda-tos, --accept-nvidia-eula, and --accept-dataset-tos flags."
        exit 1
    fi
    
    # Set acceptance flags
    [ "$NEEDS_CONDA_TOS" = true ] && ACCEPT_CONDA_TOS=true
    [ "$NEEDS_NVIDIA_EULA" = true ] && ACCEPT_NVIDIA_EULA=true
    [ "$NEEDS_DATASET_TOS" = true ] && ACCEPT_DATASET_TOS=true
    
    echo ""
    echo "✓ All terms accepted. Proceeding with installation..."
    echo ""
}

# Prompt for terms acceptance at the beginning
prompt_for_terms
select_pytorch_versions

# Create conda environment
if [ "$NEW_ENV" = true ]; then
    echo "Creating conda environment 'behavior'..."
    command -v conda >/dev/null || { echo "ERROR: Conda not found"; exit 1; }

    # Ensure we have a writable envs dir (default to workspace-local unless user overrides)
    if [ -z "$CONDA_ENVS_PATH" ]; then
        export CONDA_ENVS_PATH="$WORKDIR/.conda/envs"
    fi
    mkdir -p "$CONDA_ENVS_PATH"
    echo "Using CONDA_ENVS_PATH=$CONDA_ENVS_PATH"
    
    # Set auto-accept environment variable if user agreed to TOS
    if [ "$ACCEPT_CONDA_TOS" = true ]; then
        export CONDA_PLUGINS_AUTO_ACCEPT_TOS=yes
        echo "✓ Conda TOS auto-acceptance enabled"
    fi
    
    source "$(conda info --base)/etc/profile.d/conda.sh"

    # Check if environment already exists and exit with instructions
    ENV_PATH="$CONDA_ENVS_PATH/behavior"
    if [ -d "$ENV_PATH" ]; then
        echo ""
        echo "ERROR: Conda environment already exists at $ENV_PATH"
        echo ""
        echo "Please remove or rename the existing environment and re-run this script."
        echo ""
        exit 1
    fi

    # Create environment with only Python 3.10
    conda create -p "$ENV_PATH" python=3.10 -c conda-forge -y
    conda activate "$ENV_PATH"

    [[ "$CONDA_DEFAULT_ENV" != "behavior" && "$CONDA_DEFAULT_ENV" != "$ENV_PATH" ]] && { echo "ERROR: Failed to activate environment"; exit 1; }

    # Install numpy and setuptools via pip
    echo "Installing numpy and setuptools..."
    pip install "numpy<2" "setuptools<=79"
    
    # Install PyTorch via pip with CUDA support
    echo "Installing PyTorch with CUDA $CUDA_VERSION support..."

    PYTORCH_CUDA=$(normalize_cuda_for_pytorch "$CUDA_VERSION") || {
        echo "ERROR: Unsupported CUDA version '$CUDA_VERSION' for PyTorch wheels."
        echo "Supported CUDA versions: 12.4, 12.8, 13.0 (13.1 maps to 13.0)."
        exit 1
    }

    if [ "$PYTORCH_CUDA" != "$CUDA_VERSION" ]; then
        echo "Note: PyTorch wheels do not provide CUDA $CUDA_VERSION; using CUDA $PYTORCH_CUDA wheels instead."
    fi

	    # Determine the CUDA version string for pip URL (e.g., cu124, cu128, cu130)
	    CUDA_VER_SHORT=$(echo $PYTORCH_CUDA | sed 's/\.//g')

	    set +e
	    install_pytorch_wheels "$CUDA_VER_SHORT"
	    TORCH_INSTALL_STATUS=$?
	    set -e
	    if [ "$TORCH_INSTALL_STATUS" -ne 0 ] && [ "$CUDA_VER_SHORT" = "130" ]; then
	        echo "WARNING: Failed to install cu130 wheels; falling back to cu128."
	        install_pytorch_wheels "128"
	    elif [ "$TORCH_INSTALL_STATUS" -ne 0 ]; then
	        exit "$TORCH_INSTALL_STATUS"
	    fi
	    echo "✓ PyTorch installation completed"
fi
# Install BDDL
if [ "$BDDL" = true ]; then
    echo "Installing BDDL..."
    [ ! -d "bddl3" ] && { echo "ERROR: bddl directory not found"; exit 1; }
    pip install -e "$WORKDIR/bddl3"
fi

# Install OmniGibson with Isaac Sim
if [ "$OMNIGIBSON" = true ]; then
    echo "Installing OmniGibson..."
    [ ! -d "OmniGibson" ] && { echo "ERROR: OmniGibson directory not found"; exit 1; }
    
    # Check Python version
    PYTHON_VERSION=$(python -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
    [ "$PYTHON_VERSION" != "3.10" ] && { echo "ERROR: Python 3.10 required, found $PYTHON_VERSION"; exit 1; }
    
    # Check for conflicting environment variables
    if [[ -n "$EXP_PATH" || -n "$CARB_APP_PATH" || -n "$ISAAC_PATH" ]]; then
        echo "ERROR: Found existing Isaac Sim environment variables."
        echo "Please unset EXP_PATH, CARB_APP_PATH, and ISAAC_PATH and restart."
        exit 1
    fi
    
    # Build extras
    EXTRAS=""
    if [ "$DEV" = true ]; then
        EXTRAS="${EXTRAS}dev,"
    fi
    if [ "$PRIMITIVES" = true ]; then
        EXTRAS="${EXTRAS}primitives,"
    fi
    if [ "$EVAL" = true ]; then
        EXTRAS="${EXTRAS}eval,"
    fi
    # Remove trailing comma, if any, and add brackets only if EXTRAS is not empty
    if [ -n "$EXTRAS" ]; then
        EXTRAS="[${EXTRAS%,}]"
    fi

    # Ensure torch CUDA matches requested CUDA for builds (e.g., cu130 for CUDA 13.x)
	    PYTORCH_CUDA=$(normalize_cuda_for_pytorch "$CUDA_VERSION") || {
	        echo "ERROR: Unsupported CUDA version '$CUDA_VERSION' for PyTorch wheels."
	        echo "Supported CUDA versions: 12.4, 12.8, 13.0 (13.1 maps to 13.0)."
	        exit 1
	    }
	    ensure_pytorch_trio "$PYTORCH_CUDA"

    # If primitives are requested, patch curobo to skip strict CUDA version check
    if [ "$PRIMITIVES" = true ]; then
        CUROBO_SRC="$WORKDIR/third_party/curobo"
        if [ ! -d "$CUROBO_SRC/.git" ]; then
            echo "Cloning curobo..."
            git clone https://github.com/StanfordVL/curobo "$CUROBO_SRC"
        fi
        echo "Patching curobo for CUDA 13.0 build..."
        (cd "$CUROBO_SRC" && git fetch -q && git checkout -q cbaf7d32436160956dad190a9465360fad6aba73)
        python - << 'PY'
import pathlib

setup_py = pathlib.Path("third_party/curobo/setup.py")
text = setup_py.read_text()
marker = "CUROBO_CUDA_VERSION_CHECK_PATCH"
if marker not in text:
    insert = (
        "try:\n"
        "    import torch.utils.cpp_extension as _ce\n"
        "    _ce._check_cuda_version = lambda *args, **kwargs: None\n"
        "except Exception:\n"
        "    pass\n"
        f"# {marker}\n"
    )
    # Insert after imports block if possible
    parts = text.split("\n\n", 1)
    if len(parts) == 2:
        text = parts[0] + "\n" + insert + "\n" + parts[1]
    else:
        text = insert + text
    setup_py.write_text(text)
PY
        export CUROBO_LOCAL_PATH="$CUROBO_SRC"
    fi

	    # If primitives are requested, ensure CUDA version check won't fail on minor mismatches
	    if [ "$PRIMITIVES" = true ]; then
	        if command -v nvcc >/dev/null; then
	            TORCH_CUDA_VER=$(python -c "import torch; print(torch.version.cuda or '')")
	            if [ -n "$TORCH_CUDA_VER" ]; then
	                NVCC_VER=$(nvcc --version | sed -n 's/.*release \([0-9]\+\.[0-9]\+\).*/\1/p' | tail -n 1)
	                if [ -n "$NVCC_VER" ] && [ "$NVCC_VER" != "$TORCH_CUDA_VER" ]; then
	                    echo "Detected CUDA $NVCC_VER (nvcc) vs PyTorch CUDA $TORCH_CUDA_VER; creating a CUDA shim for build."
	                    CUDA_PATHS=$(detect_cuda_toolkit_paths) || {
	                        echo "ERROR: Found nvcc, but could not locate CUDA headers (cuda_runtime.h)."
	                        echo "ERROR: curobo requires a full CUDA toolkit (nvcc + headers) to build."
	                        echo "If using conda, try: conda install -c nvidia cuda-nvcc cuda-cudart-dev"
	                        exit 1
	                    }
	                    IFS='|' read -r NVCC_REAL CUDA_INCLUDE_DIR CUDA_LIB_DIR <<< "$CUDA_PATHS"
	                    SHIM_DIR="$WORKDIR/.cuda-shim"
	                    mkdir -p "$SHIM_DIR/bin"
	                    rm -rf "$SHIM_DIR/include" "$SHIM_DIR/lib64"
	                    ln -sfn "$CUDA_INCLUDE_DIR" "$SHIM_DIR/include"
	                    ln -sfn "$CUDA_LIB_DIR" "$SHIM_DIR/lib64"
	                    cat > "$SHIM_DIR/bin/nvcc" << EOF
#!/bin/bash
for arg in "\$@"; do
  if [ "\$arg" = "--version" ] || [ "\$arg" = "-V" ]; then
    echo "Cuda compilation tools, release ${TORCH_CUDA_VER}, V${TORCH_CUDA_VER}.0"
    exit 0
  fi
done
exec "${NVCC_REAL}" "\$@"
EOF
	                    chmod +x "$SHIM_DIR/bin/nvcc"
	                    export CUDA_HOME="$SHIM_DIR"
	                    export PATH="$SHIM_DIR/bin:$PATH"
	                    export LD_LIBRARY_PATH="$SHIM_DIR/lib64:${LD_LIBRARY_PATH:-}"
                    export NVCC="$SHIM_DIR/bin/nvcc"
                    export CMAKE_CUDA_COMPILER="$SHIM_DIR/bin/nvcc"
                fi
            fi
        fi
    fi

    pip install -e "$WORKDIR/OmniGibson$EXTRAS"

    # Install pre-commit for dev setup
    if [ "$DEV" = true ]; then
        echo "Setting up pre-commit..."
        conda install -c conda-forge pre-commit -y
        cd "$WORKDIR/OmniGibson"
        pre-commit install
        cd "$WORKDIR"
    fi
    
    # Isaac Sim installation via pip
    if [ "$ACCEPT_NVIDIA_EULA" = true ]; then
        export OMNI_KIT_ACCEPT_EULA=YES
    else
        echo "ERROR: NVIDIA EULA not accepted. Cannot install Isaac Sim."
        exit 1
    fi
    
    # Check if already installed
    if python -c "import isaacsim" 2>/dev/null; then
        echo "Isaac Sim already installed, skipping..."
    else
        echo "Installing Isaac Sim via pip..."
        
        # Helper functions
        check_glibc_old() {
            ldd --version 2>&1 | grep -qE "2\.(31|32|33)"
        }
        
        install_isaac_packages() {
            local temp_dir=$(mktemp -d)
            local packages=(
                "omniverse_kit-106.5.0.162521" "isaacsim_kernel-4.5.0.0" "isaacsim_app-4.5.0.0"
                "isaacsim_core-4.5.0.0" "isaacsim_gui-4.5.0.0" "isaacsim_utils-4.5.0.0"
                "isaacsim_storage-4.5.0.0" "isaacsim_asset-4.5.0.0" "isaacsim_sensor-4.5.0.0"
                "isaacsim_robot_motion-4.5.0.0" "isaacsim_robot-4.5.0.0" "isaacsim_benchmark-4.5.0.0"
                "isaacsim_code_editor-4.5.0.0" "isaacsim_ros1-4.5.0.0" "isaacsim_cortex-4.5.0.0"
                "isaacsim_example-4.5.0.0" "isaacsim_replicator-4.5.0.0" "isaacsim_rl-4.5.0.0"
                "isaacsim_robot_setup-4.5.0.0" "isaacsim_ros2-4.5.0.0" "isaacsim_template-4.5.0.0"
                "isaacsim_test-4.5.0.0" "isaacsim-4.5.0.0" "isaacsim_extscache_physics-4.5.0.0"
                "isaacsim_extscache_kit-4.5.0.0" "isaacsim_extscache_kit_sdk-4.5.0.0"
            )
            
            local wheel_files=()
            for pkg in "${packages[@]}"; do
                local pkg_name=${pkg%-*}
                local filename="${pkg}-cp310-none-manylinux_2_34_x86_64.whl"
                local url="https://pypi.nvidia.com/${pkg_name//_/-}/$filename"
                local filepath="$temp_dir/$filename"
                
                echo "Downloading $pkg..."
                if ! curl -sL "$url" -o "$filepath"; then
                    echo "ERROR: Failed to download $pkg"
                    rm -rf "$temp_dir"
                    return 1
                fi
                
                # Rename for older GLIBC
                if check_glibc_old; then
                    local new_filepath="${filepath/manylinux_2_34/manylinux_2_31}"
                    mv "$filepath" "$new_filepath"
                    filepath="$new_filepath"
                fi
                
                wheel_files+=("$filepath")
            done
            
            echo "Installing Isaac Sim packages..."
            pip install "${wheel_files[@]}"
            rm -rf "$temp_dir"
            
            # Verify installation
            if ! python -c "import isaacsim" 2>/dev/null; then
                echo "ERROR: Isaac Sim installation verification failed"
                return 1
            fi
        }
        
        install_isaac_packages || { echo "ERROR: Isaac Sim installation failed"; exit 1; }
        
        # Extract ISAAC_PATH from isaacsim module
        ISAAC_PATH=$(python -c "import isaacsim, os; print(os.environ.get('ISAAC_PATH', ''))" 2>/dev/null)
        
        # Fix websockets conflict - remove any pip_prebundle/websockets under extscache
        if [ -n "$ISAAC_PATH" ] && [ -d "$ISAAC_PATH/extscache" ]; then
            echo "Fixing websockets conflict..."
            find "$ISAAC_PATH/extscache" -type d -name "websockets" -path "*/pip_prebundle/*" -exec rm -rf {} + 2>/dev/null || true
        fi
    fi
    
    # Force reinstall cffi 1.17.1 to resolve compatibility issues with Isaac Sim extensions
    pip install --force-reinstall cffi==1.17.1

    # Isaac Sim extensions may depend on system GLU at runtime (libGLU.so.1).
    # Prefer installing via conda-forge when available to avoid host-level package installs.
    if command -v conda >/dev/null 2>&1 && [ -n "${CONDA_PREFIX:-}" ]; then
        conda install -c conda-forge -y libglu >/dev/null 2>&1 || true
    fi

    echo "OmniGibson installation completed successfully!"
fi

# Install JoyLo
if [ "$JOYLO" = true ]; then
    echo "Installing JoyLo..."
    [ ! -d "joylo" ] && { echo "ERROR: joylo directory not found"; exit 1; }
    pip install -e "$WORKDIR/joylo"
fi

# Install Eval
if [ "$EVAL" = true ]; then
    TORCH_VERSION=$(python -c "import torch; print(torch.__version__.split('+')[0])")
    TORCH_CUDA=$(python -c "import torch; print(torch.version.cuda or '')")
    if [ -z "$TORCH_CUDA" ]; then
        PYG_WHL_URL="https://data.pyg.org/whl/torch-${TORCH_VERSION}+cpu.html"
    else
        TORCH_CUDA_SHORT=$(echo "$TORCH_CUDA" | sed 's/\.//g')
        PYG_WHL_URL="https://data.pyg.org/whl/torch-${TORCH_VERSION}+cu${TORCH_CUDA_SHORT}.html"
    fi

    echo "Installing torch-cluster for torch ${TORCH_VERSION} (CUDA ${TORCH_CUDA:-cpu})..."
    echo "Using PyG wheels from: $PYG_WHL_URL"
    pip uninstall -y torch-cluster >/dev/null 2>&1 || true
    PIP_BUILD_CONSTRAINT= pip install --only-binary=:all: torch-cluster -f "$PYG_WHL_URL" || {
        echo "ERROR: Failed to install a torch-cluster wheel matching your PyTorch CUDA ($TORCH_CUDA)."
        echo "ERROR: Installing from source with a different CUDA toolkit will cause runtime errors like:"
        echo "  'PyTorch and torch_cluster were compiled with different CUDA versions'."
        echo "Try one of:"
        echo "  - Use a different torch CUDA build that has matching PyG wheels"
        echo "  - Install a CUDA toolkit matching torch.version.cuda and build torch-cluster from source"
        exit 1
    }
    # install av and ffmpeg
    conda install av "numpy<2" -c conda-forge -y
fi
    
# Install asset pipeline
if [ "$ASSET_PIPELINE" = true ]; then
    echo "Installing asset pipeline..."
    [ ! -d "asset_pipeline" ] && { echo "ERROR: asset_pipeline directory not found"; exit 1; }
    pip install -r "$WORKDIR/asset_pipeline/requirements.txt"
fi

# Install datasets
if [ "$DATASET" = true ]; then
    python -c "import omnigibson" || {
        echo "ERROR: OmniGibson import failed, please make sure you have omnigibson installed before downloading datasets"
        exit 1
    }
    
    echo "Installing datasets..."

    setup_hf_cache
    
    # Determine if we should accept dataset license automatically
    DATASET_ACCEPT_FLAG=""
    if [ "$ACCEPT_DATASET_TOS" = true ]; then
        DATASET_ACCEPT_FLAG="True"
    else
        DATASET_ACCEPT_FLAG="False"
    fi
    
    export OMNI_KIT_ACCEPT_EULA=YES
    
    echo "Downloading OmniGibson robot assets..."
    python -c "from omnigibson.utils.asset_utils import download_omnigibson_robot_assets; download_omnigibson_robot_assets()" || {
        echo "ERROR: OmniGibson robot assets installation failed"
        exit 1
    }

    echo "Downloading BEHAVIOR-1K assets..."
    python -c "from omnigibson.utils.asset_utils import download_behavior_1k_assets; download_behavior_1k_assets(accept_license=${DATASET_ACCEPT_FLAG})" || {
        echo "ERROR: Dataset installation failed"
        exit 1
    }

    echo "Downloading 2025 BEHAVIOR Challenge Task Instances..."
    attempt=1
    max_attempts=6
    sleep_seconds=2
    while true; do
        set +e
        python -c "from omnigibson.utils.asset_utils import download_2025_challenge_task_instances; download_2025_challenge_task_instances()"
        status=$?
        set -e
        if [ "$status" -eq 0 ]; then
            break
        fi
        if [ "$attempt" -ge "$max_attempts" ]; then
            echo "WARNING: 2025 BEHAVIOR Challenge Task Instances download failed after $max_attempts attempts."
            echo "WARNING: You can retry later with:"
            echo "  python -c \"from omnigibson.utils.asset_utils import download_2025_challenge_task_instances; download_2025_challenge_task_instances()\""
            break
        fi
        echo "WARNING: Download failed (attempt $attempt/$max_attempts). Retrying in ${sleep_seconds}s..."
        sleep "$sleep_seconds"
        attempt=$((attempt + 1))
        # Exponential backoff, capped
        sleep_seconds=$((sleep_seconds * 2))
        if [ "$sleep_seconds" -gt 60 ]; then
            sleep_seconds=60
        fi
    done
fi

echo ""
echo "=== Installation Complete! ==="
if [ "$NEW_ENV" = true ]; then echo "✓ Created conda environment 'behavior'"; fi
if [ "$OMNIGIBSON" = true ]; then echo "✓ Installed OmniGibson + Isaac Sim"; fi
if [ "$BDDL" = true ]; then echo "✓ Installed BDDL"; fi
if [ "$JOYLO" = true ]; then echo "✓ Installed JoyLo"; fi
if [ "$PRIMITIVES" = true ]; then echo "✓ Installed OmniGibson with primitives support"; fi
if [ "$EVAL" = true ]; then echo "✓ Installed evaluation support"; fi
if [ "$DATASET" = true ]; then echo "✓ Downloaded datasets"; fi
echo ""
if [ "$NEW_ENV" = true ]; then echo "To activate: conda activate behavior"; fi
