/*
Copyright (c) 2021 Roger Light <roger@atchoo.org>
Copyright (c) 2026 thin-edge.io contributors

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

SPDX-License-Identifier: Apache-2.0

Contributors:
   Roger Light - initial implementation and documentation.
   thin-edge.io contributors - message logging functionality.
*/

/*
 * Log MQTT messages with metadata.
 *
 * This plugin logs MQTT activity passing through the broker with comprehensive
 * metadata including timestamps, topics, QoS, retain flags, client IDs, and payloads.
 *
 * Every log entry carries a "type" field so publishes can be told apart from
 * control-plane events (connect/disconnect/subscribe/unsubscribe) and filtered.
 * The types emitted are:
 *   publish_in   - a PUBLISH received by the broker
 *   publish_out  - a PUBLISH delivered to a client
 *   connect      - a client finished connecting
 *   disconnect   - a client disconnected
 *   subscribe    - a client subscribed to a topic filter
 *   unsubscribe  - a client unsubscribed from a topic filter
 *
 * Note that the mosquitto plugin API does not surface the low-level MQTT
 * acknowledgement/flow-control packets (PUBACK, PUBREC, PUBREL, PUBCOMP,
 * CONNACK, SUBACK, UNSUBACK, PINGREQ, PINGRESP) - those are handled entirely
 * inside the broker and are never passed to a plugin, so they cannot be logged
 * from here.
 *
 * Configuration via environment variables:
 *   MQTT_LOG_DIR - Directory for log files (default: /var/log/mosquitto)
 *   MQTT_LOG_STDERR - Set to "1" to also log to stderr in mosquitto_sub format
 *
 * Note that this requires Mosquitto 2.1 or later (plugin API v5).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <errno.h>
#include <ctype.h>
#include <sys/time.h>
#include <stdint.h>
#include <stdbool.h>
#include <limits.h>

/*
 * On mosquitto 2.1.x the headers were reorganised under <mosquitto/...> and
 * <mosquitto.h> became an umbrella that already includes the broker and plugin
 * APIs, so a single include pulls in everything this plugin needs. (The old
 * standalone <mosquitto_broker.h> / <mosquitto_plugin.h> are now compatibility
 * shims that emit a #warning, which would break our -Werror build.)
 */
#include <mosquitto.h>

/*
 * jsmn (vendored, MIT - see compat/jsmn/jsmn.h) is a minimal JSON tokeniser used
 * only to validate that a payload is well-formed JSON before it is embedded
 * natively as the "payload_json" field of a record. JSMN_STATIC keeps its
 * symbols internal to this translation unit; JSMN_STRICT rejects malformed
 * primitives so an invalid payload can never be spliced into the log line.
 */
#define JSMN_STATIC
#define JSMN_STRICT
#include "jsmn/jsmn.h"

#define UNUSED(A) (void)(A)

#define PLUGIN_NAME "message-logger"

/* Version reported to the broker via mosquitto_plugin_set_info(). Overridable at
 * build time with -DPLUGIN_VERSION="..." — build.zig wires this to its
 * `-Dplugin-version=` option, which GoReleaser sets to the release version. */
#ifndef PLUGIN_VERSION
#define PLUGIN_VERSION "0.0.0-dev"
#endif

/* Plugin version function (plugin API v5). */
int mosquitto_plugin_version(int supported_version_count, const int *supported_versions)
{
    UNUSED(supported_version_count);
    UNUSED(supported_versions);
    return 5;
}

static mosquitto_plugin_id_t *mosq_pid = NULL;
static char log_file_path[1024] = {0};
static int log_to_stderr = 0;

/* Base64 encoding table */
static const char base64_chars[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/* Create directory recursively */
static int mkdir_recursive(const char *path, mode_t mode)
{
	char tmp[1024];
	char *p = NULL;
	size_t len;
	struct stat st;

	snprintf(tmp, sizeof(tmp), "%s", path);
	len = strlen(tmp);
	if(tmp[len - 1] == '/'){
		tmp[len - 1] = 0;
	}

	for(p = tmp + 1; *p; p++){
		if(*p == '/'){
			*p = 0;
			if(stat(tmp, &st) != 0){
				if(mkdir(tmp, mode) != 0 && errno != EEXIST){
					return -1;
				}
			}
			*p = '/';
		}
	}
	
	if(stat(tmp, &st) != 0){
		if(mkdir(tmp, mode) != 0 && errno != EEXIST){
			return -1;
		}
	}
	
	return 0;
}

/* Base64 encode */
static char *base64_encode(const unsigned char *input, size_t length)
{
	size_t output_length = 4 * ((length + 2) / 3);
	char *encoded = malloc(output_length + 1);
	
	if(!encoded) return NULL;
	
	size_t i, j;
	for(i = 0, j = 0; i < length;){
		uint32_t octet_a = i < length ? input[i++] : 0;
		uint32_t octet_b = i < length ? input[i++] : 0;
		uint32_t octet_c = i < length ? input[i++] : 0;
		uint32_t triple = (octet_a << 16) + (octet_b << 8) + octet_c;

		encoded[j++] = base64_chars[(triple >> 18) & 0x3F];
		encoded[j++] = base64_chars[(triple >> 12) & 0x3F];
		encoded[j++] = base64_chars[(triple >> 6) & 0x3F];
		encoded[j++] = base64_chars[triple & 0x3F];
	}

	/* Add padding */
	size_t mod = length % 3;
	if(mod == 1){
		encoded[output_length - 2] = '=';
		encoded[output_length - 1] = '=';
	}else if(mod == 2){
		encoded[output_length - 1] = '=';
	}

	encoded[output_length] = '\0';
	return encoded;
}

/* Convert to hex string */
static char *to_hex(const unsigned char *input, size_t length)
{
	char *hex = malloc(length * 2 + 1);
	if(!hex) return NULL;
	
	for(size_t i = 0; i < length; i++){
		sprintf(hex + (i * 2), "%02x", input[i]);
	}
	hex[length * 2] = '\0';
	return hex;
}

/* Check if payload appears to be binary */
static int is_binary(const unsigned char *payload, size_t len)
{
	if(len == 0) return 0;
	
	size_t check_len = len < 1024 ? len : 1024;
	size_t null_count = 0;
	size_t binary_count = 0;
	
	for(size_t i = 0; i < check_len; i++){
		if(payload[i] == 0){
			null_count++;
		}else if(payload[i] < 32 && payload[i] != '\t' && payload[i] != '\n' && payload[i] != '\r'){
			binary_count++;
		}
	}
	
	/* Consider binary if more than 10% null bytes or control characters */
	return (null_count > check_len / 10) || (binary_count > check_len / 10);
}

/* Strict UTF-8 validation (RFC 3629). Used to guarantee that a payload emitted
 * as a JSON string is actually valid UTF-8 - otherwise the record itself would
 * be invalid JSON and unparseable by downstream tooling. */
static int is_valid_utf8(const unsigned char *s, size_t len)
{
	size_t i = 0;

	while(i < len){
		unsigned char c = s[i];
		int n;
		unsigned int cp, min;

		if(c < 0x80){
			i++;
			continue;
		}else if((c & 0xE0) == 0xC0){
			n = 1; cp = c & 0x1F; min = 0x80;
		}else if((c & 0xF0) == 0xE0){
			n = 2; cp = c & 0x0F; min = 0x800;
		}else if((c & 0xF8) == 0xF0){
			n = 3; cp = c & 0x07; min = 0x10000;
		}else{
			return 0;
		}

		if(i + (size_t)n >= len){
			return 0; /* truncated multi-byte sequence */
		}
		for(int k = 1; k <= n; k++){
			unsigned char cc = s[i + (size_t)k];
			if((cc & 0xC0) != 0x80){
				return 0;
			}
			cp = (cp << 6) | (cc & 0x3F);
		}

		if(cp < min || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)){
			return 0; /* overlong, out of range, or surrogate */
		}
		i += (size_t)n + 1;
	}

	return 1;
}

/* Escape JSON string */
static char *json_escape(const char *str, size_t len)
{
	size_t i, j;
	size_t escaped_len = 0;
	char *escaped;
	
	/* Calculate required size */
	for(i = 0; i < len; i++){
		unsigned char c = (unsigned char)str[i];
		if(c == '"' || c == '\\' || c == '\b' || c == '\f' || c == '\n' || c == '\r' || c == '\t'){
			escaped_len += 2;
		}else if(c < 32){
			escaped_len += 6; /* \uXXXX */
		}else{
			escaped_len++;
		}
	}
	
	escaped = malloc(escaped_len + 1);
	if(!escaped) return NULL;
	
	for(i = 0, j = 0; i < len; i++){
		unsigned char c = (unsigned char)str[i];
		if(c == '"'){
			escaped[j++] = '\\';
			escaped[j++] = '"';
		}else if(c == '\\'){
			escaped[j++] = '\\';
			escaped[j++] = '\\';
		}else if(c == '\b'){
			escaped[j++] = '\\';
			escaped[j++] = 'b';
		}else if(c == '\f'){
			escaped[j++] = '\\';
			escaped[j++] = 'f';
		}else if(c == '\n'){
			escaped[j++] = '\\';
			escaped[j++] = 'n';
		}else if(c == '\r'){
			escaped[j++] = '\\';
			escaped[j++] = 'r';
		}else if(c == '\t'){
			escaped[j++] = '\\';
			escaped[j++] = 't';
		}else if(c < 32){
			sprintf(&escaped[j], "\\u%04x", c);
			j += 6;
		}else{
			escaped[j++] = (char)c;
		}
	}
	escaped[j] = '\0';
	return escaped;
}

/* Get ISO 8601 timestamp (microsecond fraction, to match the historical format) */
static void get_iso8601_timestamp(char *buf, size_t buflen, struct timespec *ts)
{
	struct tm tm_info;
	gmtime_r(&ts->tv_sec, &tm_info);
	size_t len = strftime(buf, buflen, "%Y-%m-%dT%H:%M:%S", &tm_info);
	snprintf(buf + len, buflen - len, ".%06ld+0000", (long)(ts->tv_nsec / 1000));
}

/*
 * One log entry. Fields not relevant to a given event type are omitted from the
 * output: set optional numeric fields to the "absent" sentinels below and leave
 * pointers NULL. Payload fields are only written when has_payload is set.
 */
struct log_record {
	const char *type;       /* "publish_in", "connect", ... (required) */
	const char *client_id;  /* NULL to omit */
	const char *topic;      /* NULL to omit */
	int qos;                /* <0 to omit */
	int retain;             /* <0 to omit */
	int reason;             /* INT_MIN to omit */
	const void *payload;
	uint32_t payloadlen;
	int has_payload;        /* whether payload/payloadlen apply */
};

/*
 * If `payload` is a single well-formed JSON object or array, write a minified,
 * single-line copy to *out (malloc'd, caller frees) and return 1. Otherwise
 * return 0 and leave *out untouched.
 *
 * jsmn (in strict mode) validates the structure; we additionally require the
 * top-level value to span the whole payload (only surrounding whitespace) so
 * trailing garbage or multiple values are rejected. The copy strips whitespace
 * outside strings, and any raw control byte (which is illegal in strict JSON and
 * would break the single-line record) causes us to bail. This guarantees we
 * never splice invalid or multi-line JSON into a log record.
 */
static int payload_to_minified_json(const void *payload, uint32_t payloadlen, char **out)
{
	const char *js = (const char *)payload;
	jsmn_parser parser;
	jsmntok_t stack_tokens[64];
	jsmntok_t *tokens = stack_tokens;
	unsigned int cap = sizeof(stack_tokens) / sizeof(stack_tokens[0]);
	int n;

	if(payloadlen == 0){
		return 0;
	}

	/* Tokenise, growing the token buffer if jsmn runs out of room. */
	for(;;){
		jsmn_init(&parser);
		n = jsmn_parse(&parser, js, payloadlen, tokens, cap);
		if(n == JSMN_ERROR_NOMEM){
			unsigned int newcap = cap * 2;
			jsmntok_t *bigger = realloc(tokens == stack_tokens ? NULL : tokens,
				(size_t)newcap * sizeof(*bigger));
			if(!bigger){
				if(tokens != stack_tokens) free(tokens);
				return 0;
			}
			tokens = bigger;
			cap = newcap;
			continue;
		}
		break;
	}

	int ok = 0;
	if(n >= 1 && (tokens[0].type == JSMN_OBJECT || tokens[0].type == JSMN_ARRAY)){
		int start = tokens[0].start;
		int end = tokens[0].end;
		int surrounding_ws = 1;

		for(int i = 0; i < start; i++){
			if(!isspace((unsigned char)js[i])){ surrounding_ws = 0; break; }
		}
		for(int i = end; surrounding_ws && i < (int)payloadlen; i++){
			if(!isspace((unsigned char)js[i])){ surrounding_ws = 0; break; }
		}

		if(surrounding_ws){
			char *buf = malloc((size_t)(end - start) + 1);
			if(buf){
				int in_str = 0, esc = 0, bad = 0;
				size_t j = 0;
				for(int i = start; i < end; i++){
					unsigned char c = (unsigned char)js[i];
					if(esc){
						buf[j++] = (char)c; esc = 0;
					}else if(in_str){
						if(c < 0x20){ bad = 1; break; }
						buf[j++] = (char)c;
						if(c == '\\') esc = 1;
						else if(c == '"') in_str = 0;
					}else{
						if(c == ' ' || c == '\t' || c == '\n' || c == '\r') continue;
						if(c < 0x20){ bad = 1; break; }
						buf[j++] = (char)c;
						if(c == '"') in_str = 1;
					}
				}
				if(!bad && !in_str && !esc){
					buf[j] = '\0';
					*out = buf;
					ok = 1;
				}else{
					free(buf);
				}
			}
		}
	}

	if(tokens != stack_tokens) free(tokens);
	return ok;
}

/*
 * Write the payload representation fields of a record to `out`. Each message
 * carries several encodings so the log is easy to assert on from different
 * tooling; all fields are additive (prefixed with a comma):
 *
 *   "payload_len"       - byte length (always)
 *   "payload_encoding" - "json" | "text" | "binary" (always); names the richest
 *                        representation available for this payload
 *   "payload"          - JSON-escaped string, when the payload is valid UTF-8
 *   "payload_json"     - the payload embedded as native, minified JSON, when it
 *                        is a well-formed JSON object/array
 *   "payload_base64"   - base64 of the raw bytes (always); the canonical,
 *                        lossless, byte-exact representation
 */
static void write_payload_fields(FILE *out, const void *payload, uint32_t payloadlen)
{
	/* Binary if the content looks binary or is not valid UTF-8; either way it
	 * cannot be represented as a JSON string, so only base64 is emitted. */
	int binary = payloadlen > 0 &&
		(is_binary(payload, payloadlen) || !is_valid_utf8(payload, payloadlen));
	char *json_min = NULL;
	const char *encoding;

	if(!binary && payload_to_minified_json(payload, payloadlen, &json_min)){
		encoding = "json";
	}else if(binary){
		encoding = "binary";
	}else{
		encoding = "text";
	}

	fprintf(out, ",\"payload_len\":%u,\"payload_encoding\":\"%s\"", payloadlen, encoding);

	if(!binary){
		char *escaped = json_escape((const char *)payload, payloadlen);
		if(escaped){
			fprintf(out, ",\"payload\":\"%s\"", escaped);
			free(escaped);
		}
	}

	if(json_min){
		fprintf(out, ",\"payload_json\":%s", json_min);
		free(json_min);
	}

	char *encoded = base64_encode(payload, payloadlen);
	if(encoded){
		fprintf(out, ",\"payload_base64\":\"%s\"", encoded);
		free(encoded);
	}
}

/* Write one record to the log file and/or stderr, per configuration. */
static void emit_log(struct timespec *ts, const char *timestamp_iso, const struct log_record *r)
{
	/* Log to file */
	if(log_file_path[0] != '\0'){
		FILE *log_file = fopen(log_file_path, "a");
		if(log_file){
			/* "timestamp" is a human-readable ISO 8601 string; "timestamp_unix"
			 * is the same instant as Unix seconds with nanosecond resolution,
			 * formatted as an exact sec.nsec number (a double cannot represent
			 * nanosecond epoch precision). */
			fprintf(log_file, "{\"timestamp\":\"%s\",\"timestamp_unix\":%lld.%09ld,\"type\":\"%s\"",
				timestamp_iso, (long long)ts->tv_sec, (long)ts->tv_nsec, r->type);

			if(r->client_id){
				fprintf(log_file, ",\"client_id\":\"%s\"", r->client_id);
			}
			if(r->topic){
				fprintf(log_file, ",\"topic\":\"%s\"", r->topic);
			}
			if(r->qos >= 0){
				fprintf(log_file, ",\"qos\":%d", r->qos);
			}
			if(r->retain >= 0){
				fprintf(log_file, ",\"retain\":%d", r->retain);
			}
			if(r->has_payload){
				write_payload_fields(log_file, r->payload, r->payloadlen);
			}
			if(r->reason != INT_MIN){
				fprintf(log_file, ",\"reason\":%d", r->reason);
			}

			fprintf(log_file, "}\n");
			fclose(log_file);
		}
	}

	/* Log to stderr in mosquitto_sub format */
	if(log_to_stderr){
		char *escaped_payload = NULL;
		char *hex_payload = NULL;

		if(r->has_payload && r->payloadlen > 0){
			escaped_payload = json_escape((const char *)r->payload, r->payloadlen);
			hex_payload = to_hex(r->payload, r->payloadlen);
		}

		fprintf(stderr, "MQTT_LOG: {\"timestamp\":%lld.%09ld,\"message\":{\"tst\":\"%s\",\"type\":\"%s\"",
			(long long)ts->tv_sec, (long)ts->tv_nsec,
			timestamp_iso,
			r->type);

		if(r->client_id){
			fprintf(stderr, ",\"client_id\":\"%s\"", r->client_id);
		}
		if(r->topic){
			fprintf(stderr, ",\"topic\":\"%s\"", r->topic);
		}
		if(r->qos >= 0){
			fprintf(stderr, ",\"qos\":%d", r->qos);
		}
		if(r->retain >= 0){
			fprintf(stderr, ",\"retain\":%d", r->retain);
		}
		if(r->has_payload){
			fprintf(stderr, ",\"payload_len\":%u", r->payloadlen);
		}
		if(escaped_payload){
			fprintf(stderr, ",\"payload\":\"%s\"", escaped_payload);
			free(escaped_payload);
		}
		if(r->reason != INT_MIN){
			fprintf(stderr, ",\"reason\":%d", r->reason);
		}

		fprintf(stderr, "}");

		if(hex_payload){
			fprintf(stderr, ",\"payload_hex\":\"%s\"", hex_payload);
			free(hex_payload);
		}

		fprintf(stderr, "}\n");
		fflush(stderr);
	}
}

/* Initialise a record with everything absent; callbacks fill in what applies. */
static void log_record_init(struct log_record *r, const char *type)
{
	r->type = type;
	r->client_id = NULL;
	r->topic = NULL;
	r->qos = -1;
	r->retain = -1;
	r->reason = INT_MIN;
	r->payload = NULL;
	r->payloadlen = 0;
	r->has_payload = 0;
}

/* PUBLISH in (MOSQ_EVT_MESSAGE_IN) and PUBLISH out (MOSQ_EVT_MESSAGE_OUT). */
static int callback_message(int event, void *event_data, void *userdata)
{
	struct mosquitto_evt_message *ed = event_data;
	struct timespec ts;
	char timestamp_iso[64];
	struct log_record r;

	UNUSED(userdata);

	clock_gettime(CLOCK_REALTIME, &ts);
	get_iso8601_timestamp(timestamp_iso, sizeof(timestamp_iso), &ts);

	log_record_init(&r, "publish_in");
	if(event == MOSQ_EVT_MESSAGE_OUT){
		r.type = "publish_out";
	}
	if(ed->client){
		r.client_id = mosquitto_client_id(ed->client);
	}
	r.topic = ed->topic;
	r.qos = ed->qos;
	r.retain = ed->retain ? 1 : 0;
	r.payload = ed->payload;
	r.payloadlen = ed->payloadlen;
	r.has_payload = 1;

	emit_log(&ts, timestamp_iso, &r);
	return MOSQ_ERR_SUCCESS;
}

/* DISCONNECT (MOSQ_EVT_DISCONNECT). */
static int callback_disconnect(int event, void *event_data, void *userdata)
{
	struct mosquitto_evt_disconnect *ed = event_data;
	struct timespec ts;
	char timestamp_iso[64];
	struct log_record r;

	UNUSED(event);
	UNUSED(userdata);

	clock_gettime(CLOCK_REALTIME, &ts);
	get_iso8601_timestamp(timestamp_iso, sizeof(timestamp_iso), &ts);

	log_record_init(&r, "disconnect");
	if(ed->client){
		r.client_id = mosquitto_client_id(ed->client);
	}
	r.reason = ed->reason;

	emit_log(&ts, timestamp_iso, &r);
	return MOSQ_ERR_SUCCESS;
}

/* CONNECT (MOSQ_EVT_CONNECT). */
static int callback_connect(int event, void *event_data, void *userdata)
{
	struct mosquitto_evt_connect *ed = event_data;
	struct timespec ts;
	char timestamp_iso[64];
	struct log_record r;

	UNUSED(event);
	UNUSED(userdata);

	clock_gettime(CLOCK_REALTIME, &ts);
	get_iso8601_timestamp(timestamp_iso, sizeof(timestamp_iso), &ts);

	log_record_init(&r, "connect");
	if(ed->client){
		r.client_id = mosquitto_client_id(ed->client);
	}

	emit_log(&ts, timestamp_iso, &r);
	return MOSQ_ERR_SUCCESS;
}

/* SUBSCRIBE (MOSQ_EVT_SUBSCRIBE) and UNSUBSCRIBE (MOSQ_EVT_UNSUBSCRIBE). */
static int callback_subscribe(int event, void *event_data, void *userdata)
{
	struct mosquitto_evt_subscribe *ed = event_data;
	struct timespec ts;
	char timestamp_iso[64];
	struct log_record r;

	UNUSED(userdata);

	clock_gettime(CLOCK_REALTIME, &ts);
	get_iso8601_timestamp(timestamp_iso, sizeof(timestamp_iso), &ts);

	log_record_init(&r, event == MOSQ_EVT_UNSUBSCRIBE ? "unsubscribe" : "subscribe");
	if(ed->client){
		r.client_id = mosquitto_client_id(ed->client);
	}
	r.topic = ed->data.topic_filter;
	/* QoS lives in the low two bits of the subscription options byte; it is not
	 * meaningful for an unsubscribe, which carries only a topic filter. */
	if(event != MOSQ_EVT_UNSUBSCRIBE){
		r.qos = ed->data.options & 0x03;
	}

	emit_log(&ts, timestamp_iso, &r);
	return MOSQ_ERR_SUCCESS;
}


int mosquitto_plugin_init(mosquitto_plugin_id_t *identifier, void **user_data, struct mosquitto_opt *opts, int opt_count)
{
	const char *log_dir;
	char date_str[32];
	time_t now;
	struct tm *tm_info;
	
	UNUSED(user_data);
	UNUSED(opts);
	UNUSED(opt_count);

	mosq_pid = identifier;
	
	/* Get log directory from environment */
	log_dir = getenv("MQTT_LOG_DIR");
	if(!log_dir){
		log_dir = "/var/log/mosquitto";
	}
	
	/* Create log directory if it doesn't exist */
	if(mkdir_recursive(log_dir, 0755) != 0){
		fprintf(stderr, "Warning: Failed to create log directory %s: %s\n", log_dir, strerror(errno));
		/* Continue anyway, we'll try to write */
	}
	
	/* Create log file path with date */
	now = time(NULL);
	tm_info = localtime(&now);
	strftime(date_str, sizeof(date_str), "%Y%m%d", tm_info);
	snprintf(log_file_path, sizeof(log_file_path), "%s/mqtt-messages-%s.log", log_dir, date_str);
	
	/* Check if stderr logging is enabled */
	const char *stderr_env = getenv("MQTT_LOG_STDERR");
	if(stderr_env && strcmp(stderr_env, "1") == 0){
		log_to_stderr = 1;
	}
	
	/* Advertise the plugin name/version to the broker. */
	mosquitto_plugin_set_info(mosq_pid, PLUGIN_NAME, PLUGIN_VERSION);

	mosquitto_callback_register(mosq_pid, MOSQ_EVT_MESSAGE_IN, callback_message, NULL, NULL);
	mosquitto_callback_register(mosq_pid, MOSQ_EVT_MESSAGE_OUT, callback_message, NULL, NULL);
	mosquitto_callback_register(mosq_pid, MOSQ_EVT_DISCONNECT, callback_disconnect, NULL, NULL);
	mosquitto_callback_register(mosq_pid, MOSQ_EVT_CONNECT, callback_connect, NULL, NULL);
	mosquitto_callback_register(mosq_pid, MOSQ_EVT_SUBSCRIBE, callback_subscribe, NULL, NULL);
	mosquitto_callback_register(mosq_pid, MOSQ_EVT_UNSUBSCRIBE, callback_subscribe, NULL, NULL);

	return MOSQ_ERR_SUCCESS;
}


int mosquitto_plugin_cleanup(void *user_data, struct mosquitto_opt *opts, int opt_count)
{
	UNUSED(user_data);
	UNUSED(opts);
	UNUSED(opt_count);

	return MOSQ_ERR_SUCCESS;
}
