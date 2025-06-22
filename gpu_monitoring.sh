#!/bin/bash

SERVER_NAME="FARM9"

LOG_FILE="gpu_container_usage.log"
TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")


echo "==================== [$TIMESTAMP] GPU Container Check ====================" >> "$LOG_FILE"

# 호스트의 GPU 상태 먼저 확인
echo "▶️ Host GPU Status:" >> "$LOG_FILE"
HOST_GPU_INFO=$(nvidia-smi --query-gpu=name,utilization.gpu --format=csv,noheader,nounits 2>&1)
HOST_GPU_STATUS=$?

if [ $HOST_GPU_STATUS -eq 0 ]; then
    echo "   ✅ Host GPU access: YES" >> "$LOG_FILE"
    echo "   🔧 Host GPU usage:" >> "$LOG_FILE"
    while IFS= read -r line; do
        GPU_NAME=$(echo "$line" | cut -d',' -f1 | xargs)
        GPU_UTIL=$(echo "$line" | cut -d',' -f2 | xargs)
        echo "     - $GPU_NAME: ${GPU_UTIL}% usage" >> "$LOG_FILE"
    done <<< "$HOST_GPU_INFO"
else
    # 슬랙 알림 전송 (호스트 GPU 접근 실패 시)
    curl -X POST -H 'Content-type: application/json' \
      --data "{\"text\":\"[ALERT] Host GPU access failed on server: $SERVER_NAME\"}" \
      https://hooks.slack.com/services/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

    echo "   ❌ Host GPU access: NO" >> "$LOG_FILE"
    echo "      ↪ Error: $HOST_GPU_INFO" >> "$LOG_FILE"
fi

echo "" >> "$LOG_FILE"

# 모든 실행 중인 컨테이너 순회
docker ps --format "{{.ID}} {{.Names}} {{.Image}}" | while read -r CONTAINER_ID CONTAINER_NAME CONTAINER_IMAGE; do
    echo "▶️ Container: $CONTAINER_NAME ($CONTAINER_ID) [$CONTAINER_IMAGE]" >> "$LOG_FILE"

    # 22번 포트 매핑된 호스트 포트 확인
    HOST_PORT=$(docker port "$CONTAINER_ID" 22 2>/dev/null | awk -F: '{print $2}' | tr -d ' ')
    [ -z "$HOST_PORT" ] && HOST_PORT="(not exposed)"
    echo "   ↪ SSH (port 22) mapped to host: $HOST_PORT" >> "$LOG_FILE"

    # 컨테이너 내부에서 nvidia-smi 실행 시도
    OUTPUT=$(docker exec "$CONTAINER_ID" nvidia-smi --query-gpu=name,utilization.gpu --format=csv,noheader,nounits 2>&1)
    STATUS=$?

    if [ $STATUS -eq 0 ]; then
        echo "   ✅ GPU access: YES" >> "$LOG_FILE"
        echo "   🔧 GPU usage:" >> "$LOG_FILE"
        while IFS= read -r line; do
            GPU_NAME=$(echo "$line" | cut -d',' -f1 | xargs)
            GPU_UTIL=$(echo "$line" | cut -d',' -f2 | xargs)
            echo "     - $GPU_NAME: ${GPU_UTIL}% usage" >> "$LOG_FILE"
        done <<< "$OUTPUT"

    else
        echo "   ❌ GPU access: NO (initial)" >> "$LOG_FILE"
        echo "      ↪ Error: $OUTPUT" >> "$LOG_FILE"

        # 커널 모듈 로딩 상태 확인
        echo "   🔍 Checking loaded NVIDIA kernel modules..." >> "$LOG_FILE"
        lsmod | grep -E 'nvidia(_uvm)?' >> "$LOG_FILE"

        echo "   🔄 Attempting to reload nvidia modules on host..." >> "$LOG_FILE"
        sudo rmmod nvidia_uvm nvidia_modeset nvidia_drm nvidia 2>/dev/null
        sudo modprobe nvidia && sudo modprobe nvidia_uvm

        sleep 2  # 모듈 재로드 후 안정화 대기

        OUTPUT2=$(docker exec "$CONTAINER_ID" nvidia-smi --query-gpu=name,utilization.gpu --format=csv,noheader,nounits 2>&1)
        STATUS2=$?

        if [ $STATUS2 -eq 0 ]; then
            echo "   ✅ GPU access: YES (after module reload)" >> "$LOG_FILE"
            echo "   🔧 GPU usage:" >> "$LOG_FILE"
            while IFS= read -r line; do
                GPU_NAME=$(echo "$line" | cut -d',' -f1 | xargs)
                GPU_UTIL=$(echo "$line" | cut -d',' -f2 | xargs)
                echo "     - $GPU_NAME: ${GPU_UTIL}% usage" >> "$LOG_FILE"
            done <<< "$OUTPUT2"
        else
            echo "   ❌ GPU access: STILL FAILING after module reload" >> "$LOG_FILE"
            # 슬랙 알림 전송
            curl -X POST -H 'Content-type: application/json' \
              --data "{\"text\":\"[ALERT] GPU access still failing after reload in container: $CONTAINER_NAME ($CONTAINER_ID)\"}" \
              https://hooks.slack.com/services/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
            echo "      ↪ Error: $OUTPUT2" >> "$LOG_FILE"
        fi
    fi

    echo "" >> "$LOG_FILE"
done

echo "" >> "$LOG_FILE"