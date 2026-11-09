#!/bin/bash

hex_input=$1

# Remove 0x if it exists
hex_input=${hex_input#0x}
echo "${hex_input}"
# Convert to decimal
decimal_output=$(echo "ibase=16; $hex_input" | bc)

echo $decimal_output

