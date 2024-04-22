
endpoint=$1
api_key=$2
slot=$3

#echo curl -H "Content-Type: application/json" "${endpoint}/eth/v2/debug/beacon/states/${slot}"
curl -H "Content-Type: application/json" "${endpoint}/eth/v2/debug/beacon/states/${slot}" > beacon_state_${slot}.json
curl -H "Content-Type: application/json" "${endpoint}/eth/v2/beacon/blocks/${slot}" > beacon_block_${slot}.json
curl -H "Content-Type: application/json" "${endpoint}/eth/v1/beacon/headers/${slot}" > block_header_${slot}.json

#curl -H "X-goog-api-key: ${api_key}" -H "Content-Type: application/json" "${endpoint}/eth/v2/debug/beacon/states/${slot}" > beacon_state_${slot}.json
#curl -H "X-goog-api-key: ${api_key}" -H "Content-Type: application/json" "${endpoint}/eth/v2/beacon/blocks/${slot}" > beacon_block_${slot}.json
#curl -H "X-goog-api-key: ${api_key}" -H "Content-Type: application/json" "${endpoint}/eth/v1/beacon/headers/${slot}" > block_header_${slot}.json
