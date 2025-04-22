#!/bin/bash

# Debug: Log start
echo "Starting c.sh..." >&2

# Check Python3
if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: Python3 is not installed." >&2
    exit 1
fi

# Check ffprobe
if ! command -v ffprobe >/dev/null 2>&1; then
    echo "Error: ffprobe is not installed." >&2
    exit 1
fi

# Debug: Check stdin
if [ ! -t 0 ]; then
    echo "Warning: stdin is not a TTY. Running in non-interactive mode. Using default edge (Edge-02)." >&2
    echo "Debug: stdin is /proc/$$/fd/0 -> $(readlink /proc/$$/fd/0)" >&2
    DEFAULT_EDGE="Edge-02"
else
    echo "Choose the Edge device id:" >&2
    echo "Debug: stdin is a TTY, proceeding with interactive prompt." >&2
fi

# Create temporary Python script
temp_py_file=$(mktemp /tmp/fetch_rtsp.XXXXXX.py)
echo "Debug: Created temp Python script: $temp_py_file" >&2

cat << EOF > "$temp_py_file"
import json
import sys
import urllib.request
import subprocess

print("Debug: Running Python script...", file=sys.stderr)

def is_rtsp_online(rtsp_link, device_name):
    try:
        result = subprocess.run(
            ["ffprobe", "-v", "quiet", rtsp_link],
            timeout=5,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL
        )
        status = "Online" if result.returncode == 0 else "Idle or Offline"
        print(f"Debug: Checking {device_name} with ffprobe, {status}", file=sys.stderr)
        return result.returncode == 0
    except subprocess.TimeoutExpired:
        print(f"Debug: Checking {device_name} with ffprobe, Idle or Offline", file=sys.stderr)
        return False
    except Exception as e:
        print(f"Debug: Checking {device_name} with ffprobe, Idle or Offline", file=sys.stderr)
        return False

API_URL = "http://192.168.0.105:3000/api/edge-devices"
try:
    print("Debug: Fetching from API...", file=sys.stderr)
    with urllib.request.urlopen(API_URL, timeout=10) as response:
        data = json.loads(response.read().decode())
    print("Debug: API fetch successful", file=sys.stderr)
except Exception as e:
    print(f"Error: API fetch failed - {e}", file=sys.stderr)
    sys.exit(1)
if not isinstance(data, list):
    print("Error: Expected list of edge devices", file=sys.stderr)
    sys.exit(1)
print("Available Edge Devices:", file=sys.stderr)
for edge in data:
    print(f"{edge['name']}")
edge_name = None
try:
    if sys.stdin.isatty():
        print("Enter the Edge id in {Edge-{id}} format:", file=sys.stderr)
        while True:
            edge_name = input().strip()
            print(f"Debug: Received edge name: {edge_name}", file=sys.stderr)
            selected_edge = next((e for e in data if e["name"] == edge_name), None)
            if selected_edge:
                break
            print(f"Error: Edge '{edge_name}' not found", file=sys.stderr)
    else:
        print("Debug: Non-interactive mode, using default edge...", file=sys.stderr)
        edge_name = "$DEFAULT_EDGE"  # Will be replaced by shell
        selected_edge = next((e for e in data if e["name"] == edge_name), None)
        if not selected_edge:
            print(f"Error: Default edge '{edge_name}' not found", file=sys.stderr)
            sys.exit(1)
except EOFError:
    print("Error: No edge name provided", file=sys.stderr)
    sys.exit(1)
except KeyboardInterrupt:
    print("\nError: Input interrupted", file=sys.stderr)
    sys.exit(1)
devices = selected_edge.get("devices", [])
if not devices:
    print(f"Error: No devices for Edge '{edge_name}'", file=sys.stderr)
    sys.exit(1)
rtsp_links = [(d["rtsp_link"].strip(), d["name"]) for d in devices if "rtsp_link" in d and d["rtsp_link"]]
print("Debug: Checking the following RTSP links:", file=sys.stderr)
for link, name in rtsp_links:
    print(f"  {link} ({name})", file=sys.stderr)
print(f"Debug: Found {len(rtsp_links)} RTSP links", file=sys.stderr)
if not rtsp_links:
    print("no rtsps are defined", file=sys.stderr)
    sys.exit(1)
online_rtsp_links = [link for link, name in rtsp_links if is_rtsp_online(link, name)]
print(f"Debug: Found {len(online_rtsp_links)} online RTSP links", file=sys.stderr)
if online_rtsp_links:
    print("fetching rtsp list: " + ", ".join(online_rtsp_links), file=sys.stderr)
    for link in online_rtsp_links:
        print(link)
else:
    print("no rtsps are defined", file=sys.stderr)
    sys.exit(1)
EOF

# Replace $DEFAULT_EDGE in the Python script
sed -i "s|\"\$DEFAULT_EDGE\"|\"$DEFAULT_EDGE\"|" "$temp_py_file"

# Run Python script, capture stdout for RTSP links
echo "Debug: Running Python script..." >&2
RTSP_STREAMS=()
while IFS= read -r line; do
    if [[ "$line" =~ ^rtsp:// ]]; then
        RTSP_STREAMS+=("$line")
        echo "Debug: Captured RTSP stream: $line" >&2
    else
        echo "$line" >&2
    fi
done < <(python3 -u "$temp_py_file" 2>&1)
python_exit_code=$?

# Clean up
rm "$temp_py_file"
echo "Debug: Removed temp Python script" >&2

# Check Python execution
if [ $python_exit_code -ne 0 ]; then
    echo "Error: Python script failed with exit code $python_exit_code" >&2
    exit 1
fi

# If no RTSP streams, exit
if [ ${#RTSP_STREAMS[@]} -eq 0 ]; then
    echo "Error: No RTSP streams captured" >&2
    exit 1
fi

# Write to temporary file
temp_file=$(mktemp)
echo "Debug: Created temp file for streams: $temp_file" >&2
for stream in "${RTSP_STREAMS[@]}"; do
    echo "$stream" >> "$temp_file"
done

# Prompt user for upload before starting a.sh
if [ -t 0 ]; then
    echo "Would you like to upload the files to GitHub? (yes/no)" >&2
    read -r upload_choice
    if [[ "$upload_choice" =~ ^[Yy][Ee][Ss]$ ]]; then
        echo "Proceeding with upload..." >&2

        # GitHub Upload Logic
        GITHUB_OWNER="yourusername"  # Replace with your GitHub username
        GITHUB_REPO="yourrepo"      # Replace with your repository name
        GITHUB_TOKEN="your_token"   # Replace with your GitHub Personal Access Token
        COMMIT_MESSAGE="Dynamic upload of project files"
        RELEASE_TAG="v$(date +%Y%m%d%H%M)"
        RELEASE_NAME="Project Release $(date +%Y-%m-%d %H:%M)"

        # Create temporary directory for zip
        temp_dir=$(mktemp -d /tmp/project.XXXXXX)
        echo "Debug: Created temp directory: $temp_dir" >&2
        mkdir -p "$temp_dir/models"

        # Copy scripts and model files to temp directory
        cp /home/dlstreamer/Test/c.sh /home/dlstreamer/Test/a.sh /home/difinative/openvino_env/Test_Scripts/Diageo/web.py "$temp_dir/"
        model_dir="/home/dlstreamer/models/warehouse3"
        cp "$model_dir/cementbag_v7.bin" "$model_dir/cementbag_v7.xml" "$model_dir/metadata.yaml" "$temp_dir/models/"
        echo "Debug: Copied scripts and model files to $temp_dir" >&2

        # Create zip file
        zip_file="/tmp/project.zip"
        cd "$temp_dir" && zip -r "$zip_file" . >/dev/null
        echo "Debug: Created zip file: $zip_file" >&2

        # Upload to GitHub
        # Step 1: Upload individual files
        for file in c.sh a.sh web.py models/cementbag_v7.bin models/cementbag_v7.xml models/metadata.yaml; do
            echo "Debug: Uploading $file to GitHub..." >&2
            base64_content=$(base64 -w 0 "$temp_dir/$file")
            curl -X PUT \
                -H "Authorization: token $GITHUB_TOKEN" \
                -H "Accept: application/vnd.github.v3+json" \
                -d "{\"message\":\"$COMMIT_MESSAGE\",\"content\":\"$base64_content\"}" \
                "https://api.github.com/repos/$GITHUB_OWNER/$GITHUB_REPO/contents/$file" >/dev/null 2>&1
            if [ $? -eq 0 ]; then
                echo "Debug: Successfully uploaded $file" >&2
            else
                echo "Error: Failed to upload $file" >&2
                rm -rf "$temp_dir" "$zip_file"
                exit 1
            fi
        done

        # Step 2: Create a release
        echo "Debug: Creating GitHub release..." >&2
        release_response=$(curl -X POST \
            -H "Authorization: token $GITHUB_TOKEN" \
            -H "Accept: application/vnd.github.v3+json" \
            -d "{\"tag_name\":\"$RELEASE_TAG\",\"name\":\"$RELEASE_NAME\",\"body\":\"Dynamic release with updated project files\"}" \
            "https://api.github.com/repos/$GITHUB_OWNER/$GITHUB_REPO/releases")
        release_id=$(echo "$release_response" | grep -o '"id": *[0-9]*' | cut -d: -f2 | tr -d ' ')
        if [ -z "$release_id" ]; then
            echo "Error: Failed to create release" >&2
            rm -rf "$temp_dir" "$zip_file"
            exit 1
        fi
        echo "Debug: Created release with ID $release_id" >&2

        # Step 3: Upload zip as release asset
        echo "Debug: Uploading zip to release..." >&2
        curl -X POST \
            -H "Authorization: token $GITHUB_TOKEN" \
            -H "Accept: application/vnd.github.v3+json" \
            -H "Content-Type: application/zip" \
            --data-binary @"$zip_file" \
            "https://uploads.github.com/repos/$GITHUB_OWNER/$GITHUB_REPO/releases/$release_id/assets?name=project.zip" >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            echo "Debug: Successfully uploaded zip to release" >&2
            echo "Download URL: https://github.com/$GITHUB_OWNER/$GITHUB_REPO/releases/download/$RELEASE_TAG/project.zip" >&2
        else
            echo "Error: Failed to upload zip to release" >&2
            rm -rf "$temp_dir" "$zip_file"
            exit 1
        fi

        # Clean up
        rm -rf "$temp_dir" "$zip_file"
        echo "Debug: Removed temp directory and zip file" >&2
    else
        echo "Upload skipped. Proceeding without uploading..." >&2
    fi
fi

# Process online streams, suppress 'Generated pipeline:' and display real-time output
echo "Processing..." >&2
# Run a.sh in the background and filter output using tee and grep
./a.sh "$temp_file" 2>&1 | tee /tmp/a.sh_output | grep -v "Generated pipeline:" &
a_sh_pid=$!
# Wait for manual termination (non-blocking, script continues)
exit_code=0

# Clean up
rm "$temp_file"
echo "Debug: Removed temp stream file" >&2

exit $exit_code
