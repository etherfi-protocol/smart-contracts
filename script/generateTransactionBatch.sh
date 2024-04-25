#!/bin/bash

txns_dir="../release/logs/txns"

# Output file located in the same directory as txns
output_file="$(dirname $txns_dir)/transactionBatch.json"

# add the static meta data to the file
echo '{ "version": "1.0", "chainId": "1", "meta": { "name": "Transactions Batch", "description": "", "txBuilderVersion": "1.16.5", "createdFromSafeAddress": "0xcdd57D11476c22d265722F68390b036f3DA48c21" }, "transactions": [' > $output_file

# Process transaction file
first=true
for file in ../release/logs/txns/*.json; do
    if [ "$first" = true ]; then
        first=false
    else
        echo ',' >> $output_file # Add a comma between objects if not the last object in the array
    fi

    # Extract relevant fields and format the transaction JSON
    jq '{ to: .to, value: (.value | tostring), data: .data }' $file >> $output_file
done

echo '] }' >> $output_file

echo "JSON has been created at $output_file"
