#!/bin/bash

txns_dir="./release/logs/txns"

# Extract the block number from the first transaction file name
block_number=$(basename $(ls $txns_dir/*.json | head -1) | cut -d '.' -f 1)

# output file located in the same directory as txns
output_file="${block_number}.transactionBatch.json"

# add the static meta data to the file
echo '{ "version": "1.0", "chainId": "1", "meta": { "name": "Transactions Batch", "description": "", "txBuilderVersion": "1.16.5", "createdFromSafeAddress": "0xcdd57D11476c22d265722F68390b036f3DA48c21" }, "transactions": [' > $output_file

# process transaction file
first=true
for file in ${txns_dir}/*.json; do
    echo "Processing" $file

    if [ "$first" = true ]; then
        first=false
    else
        echo ',' >> $output_file # add a comma between objects if not the last transaction in the array
    fi

    # extract relevant fields and format the transaction JSON
    jq '{ to: .to, value: (.value | tostring), data: .data }' $file >> $output_file

    # make sure the same file won't be used again
    rm $file
done

echo '] }' >> $output_file

echo "JSON has been created at $output_file"
