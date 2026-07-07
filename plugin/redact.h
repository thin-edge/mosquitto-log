/*
Copyright (c) 2026 thin-edge.io contributors

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

SPDX-License-Identifier: Apache-2.0
*/

#ifndef REDACT_H
#define REDACT_H

#include <stdint.h>

/*
 * String that replaces every redacted value. Kept as a single define so the
 * placeholder is a one-line change. It is emitted as a JSON string value for
 * JSON payloads (so the record stays valid JSON) and as a raw field for the
 * SmartREST text rules.
 */
#define REDACT_MASK "***"

/*
 * Redact sensitive data from an MQTT payload using the hard-coded thin-edge.io
 * rules (see redact.c for the full rule set):
 *
 *   - topic "c8y/s/dat"  -> Cumulocity JWT response "71,<jwt>"; the token is
 *                            masked, the "71" template id is kept.
 *   - topic "c8y/s/dcr"  -> Cumulocity device-credentials response
 *                            "70,<tenant>,<username>,<password>"; username and
 *                            password are masked, template id and tenant kept.
 *   - otherwise, any JSON payload has the value of well-known sensitive keys
 *     (password, token, access_token, secret, apikey - case-insensitive, at any
 *     depth) replaced with the mask.
 *
 * Redaction operates on the raw bytes: on a match a new buffer is allocated,
 * stored in *out (NUL-terminated; byte length in *outlen) and 1 is returned.
 * The caller owns *out and must free() it. Every downstream representation
 * (payload / payload_json / payload_base64 / payload_hex) is then derived from
 * this buffer, so no encoding can leak the original secret.
 *
 * When nothing matches, returns 0 and leaves *out and *outlen untouched — the
 * caller keeps using the original payload (zero copy).
 */
int redact_payload(const char *topic,
                   const void *payload, uint32_t payloadlen,
                   char **out, uint32_t *outlen);

#endif /* REDACT_H */
