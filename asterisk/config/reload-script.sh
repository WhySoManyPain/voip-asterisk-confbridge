#!/bin/bash

docker exec voip-asterisk asterisk -rx "pjsip reload"
docker exec voip-asterisk asterisk -rx "dialplan reload"
docker exec voip-asterisk asterisk -rx "module reload res_rtp_asterisk.so"
docker exec voip-asterisk asterisk -rx "moh reload"
docker exec voip-asterisk asterisk -rx "module reload app_confbridge.so"

echo "aktualizace probehla"
