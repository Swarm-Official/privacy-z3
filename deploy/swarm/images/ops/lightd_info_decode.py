#!/usr/bin/env python3
"""Decode a gRPC GetLightdInfo response into JSON, from stdin.

Why by hand: the check this serves needs one string out of one unary response,
and the alternatives are worse. `grpcurl` means a binary downloaded into the
image at build time; the generated Python stubs mean protoc and grpcio in a
deploy image whose entire job is to run curl. The wire format of a unary gRPC
response is a five-byte frame around a protobuf message, and protobuf's
field-tag encoding is stable by definition, so 60 lines here replace both.

It is deliberately partial: fields it does not know are skipped by wire type,
so a newer server adding fields still decodes. The field numbers come from
LightdInfo in the lightwallet protocol's service.proto.

A naive `grep swarm-testnet` over the raw bytes would NOT do: `branch` (field 9)
is build metadata, and on a build from the `swarm-testnet-support` branch it
contains that substring too. The point of decoding is to read field 4 and
nothing else.
"""

import json
import sys

# LightdInfo field numbers, from the lightwallet protocol's service.proto.
STRING_FIELDS = {
    1: "version",
    2: "vendor",
    4: "chain_name",
    6: "consensus_branch_id",
    8: "git_commit",
    9: "branch",
    10: "build_date",
    11: "build_user",
    13: "zcashd_build",
    14: "zcashd_subversion",
    15: "donation_address",
    16: "upgrade_name",
    18: "lightwallet_protocol_version",
}
VARINT_FIELDS = {
    3: "taddr_support",
    5: "sapling_activation_height",
    7: "block_height",
    12: "estimated_height",
    17: "upgrade_height",
}


def read_varint(buf, i):
    result = 0
    shift = 0
    while True:
        if i >= len(buf):
            raise ValueError("truncated varint")
        byte = buf[i]
        i += 1
        result |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return result, i
        shift += 7
        if shift > 63:
            raise ValueError("varint too long")


def decode_message(buf):
    fields = {}
    i = 0
    while i < len(buf):
        key, i = read_varint(buf, i)
        number, wire_type = key >> 3, key & 0x07
        if wire_type == 0:
            value, i = read_varint(buf, i)
            if number in VARINT_FIELDS:
                name = VARINT_FIELDS[number]
                fields[name] = bool(value) if name == "taddr_support" else value
        elif wire_type == 2:
            length, i = read_varint(buf, i)
            chunk, i = buf[i : i + length], i + length
            if len(chunk) != length:
                raise ValueError("truncated length-delimited field %d" % number)
            if number in STRING_FIELDS:
                fields[STRING_FIELDS[number]] = chunk.decode("utf-8", "replace")
        elif wire_type == 5:
            i += 4
        elif wire_type == 1:
            i += 8
        else:
            raise ValueError("unsupported wire type %d on field %d" % (wire_type, number))
    return fields


def main():
    body = sys.stdin.buffer.read()
    if len(body) < 5:
        sys.exit("gRPC response is %d bytes; expected at least the 5-byte frame header" % len(body))
    compressed = body[0]
    if compressed:
        sys.exit("gRPC response is compressed; this decoder reads identity-encoded frames only")
    length = int.from_bytes(body[1:5], "big")
    message = body[5 : 5 + length]
    if len(message) != length:
        sys.exit("gRPC frame claims %d bytes but carries %d" % (length, len(message)))
    try:
        print(json.dumps(decode_message(message), indent=2, sort_keys=True))
    except ValueError as error:
        sys.exit("cannot decode the LightdInfo message: %s" % error)


if __name__ == "__main__":
    main()
