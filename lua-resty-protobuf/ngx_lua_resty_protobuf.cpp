#include <chrono>
#include <stack>
#include <random>
#include <string>
#include <sys/uio.h>
#include <unistd.h>
#include <arpa/inet.h>
#include "opentelemetry/proto/trace/v1/trace.pb.h"

#define C_API extern "C"
#define IOVEC_MAX 1024
#define MAX_BUFFERED_SIZE (64 * 1024 - 1 - 8 - 20)

using std::stack;
using std::string;
using std::default_random_engine;
using std::uniform_int_distribution;
using google::protobuf::Arena;
using namespace std::chrono;
using namespace google::protobuf;
using namespace opentelemetry::proto::trace::v1;
using namespace opentelemetry::proto::common::v1;

static default_random_engine g_rng;
static uniform_int_distribution<uint64_t> g_dist;

static int g_udp_socket = -1;
static string g_serialized;


class Handle {
private:
    stack<Span*> m_context;
    Arena m_arena;

    // 16 bytes trace id
    string m_trace_id;

    string m_serialized;

    uint32_t _decode_big_endian(const uint8_t* buffer) {
        return (buffer[0] << 24) | (buffer[1] << 16) | (buffer[2] << 8) | buffer[3];
    }

    void _encode_big_endian(uint8_t* buffer, uint32_t value) {
        buffer[0] = (value >> 24) & 0xFF;
        buffer[1] = (value >> 16) & 0xFF;
        buffer[2] = (value >> 8) & 0xFF;
        buffer[3] = value & 0xFF;
    }

    void _open_udp_socket() noexcept(false) {
        if (g_udp_socket != -1) {
            return;
        }

        struct sockaddr_in servaddr;
        if ((g_udp_socket = socket(AF_INET, SOCK_DGRAM, 0)) < 0) {
            throw std::runtime_error("socket creation failed");
        }

        memset(&servaddr, 0, sizeof(servaddr));
        servaddr.sin_family = AF_INET;
        servaddr.sin_port = htons(9999);
        servaddr.sin_addr.s_addr = inet_addr("127.0.0.1");

        if (connect(g_udp_socket, (struct sockaddr *)&servaddr, sizeof(servaddr)) == -1) {
            throw std::runtime_error("connect failed: " + std::string(strerror(errno)));
        }
    }

    void _flush_buffer() noexcept(false) {
        _open_udp_socket();
        if (send(g_udp_socket, g_serialized.c_str(), g_serialized.size(), 0) == -1) {
            throw std::runtime_error("send failed: " + std::string(strerror(errno)));
        }

        g_serialized.clear();
    }

    uint64_t _now_unix_nano() {
        auto now = system_clock::now();
        return duration_cast<std::chrono::nanoseconds>(
                    now.time_since_epoch()).count();
    }

    uint64_t _gen_random_8bytes() {
        return g_dist(g_rng);
    }

    string _gen_random_trace_id() {
        uint64_t trace_id[2] = {_gen_random_8bytes(), _gen_random_8bytes()};
        return string((char*)trace_id, 16);
    }

    string _gen_random_span_id() {
        uint64_t span_id = _gen_random_8bytes();
        return string((char*)&span_id, 8);
    }

    bool _has_parent_span() {
        return m_context.size() != 0;
    }

    const string& _get_parent_span_id() {
        return m_context.top()->span_id();
    }

public:
    Handle() {
        m_trace_id = _gen_random_trace_id();
        m_serialized.reserve(2048);
    }

    ~Handle() noexcept(false) {
        if (!m_context.empty()) {
            throw std::runtime_error("span not closed");
        }

        if (m_serialized.length() >= MAX_BUFFERED_SIZE) {
            throw std::runtime_error("serialized data too large");
        }

        if (g_serialized.length() + m_serialized.length() >= MAX_BUFFERED_SIZE) {
            _flush_buffer();
        }

        g_serialized.append(m_serialized);
    }

    void enter_span(const char* name, uint64_t len) {
        Span* span = Arena::CreateMessage<Span>(&m_arena);
        span->set_name(std::string(name, len));
        span->set_start_time_unix_nano(_now_unix_nano());
        span->set_trace_id(m_trace_id);
        span->set_span_id(_gen_random_span_id());

        if (_has_parent_span()) {
            span->set_parent_span_id(_get_parent_span_id());
        }

        m_context.push(span);
    }

    void add_string_attribute(const char* name, uint64_t name_len, const char* val, uint64_t val_len) {
        KeyValue* kv = Arena::CreateMessage<KeyValue>(&m_arena);
        kv->set_key(std::string(name, name_len));
        
        AnyValue* any_val = Arena::CreateMessage<AnyValue>(&m_arena);
        any_val->set_string_value(std::string(val, val_len));

        kv->set_allocated_value(any_val);
    }

    void add_bool_attribute(const char* name, uint64_t name_len, int32_t val) {
        KeyValue* kv = Arena::CreateMessage<KeyValue>(&m_arena);
        kv->set_key(std::string(name, name_len));
        
        AnyValue* any_val = Arena::CreateMessage<AnyValue>(&m_arena);
        any_val->set_bool_value(val == 0 ? false : true);

        kv->set_allocated_value(any_val);
    }

    void add_int64_attribute(const char* name, uint64_t name_len, int64_t val) {
        KeyValue* kv = Arena::CreateMessage<KeyValue>(&m_arena);
        kv->set_key(std::string(name, name_len));
        
        AnyValue* any_val = Arena::CreateMessage<AnyValue>(&m_arena);
        any_val->set_int_value(val);

        kv->set_allocated_value(any_val);
    }

    void add_double_attribute(const char* name, uint64_t name_len, double val) {
        KeyValue* kv = Arena::CreateMessage<KeyValue>(&m_arena);
        kv->set_key(std::string(name, name_len));
        
        AnyValue* any_val = Arena::CreateMessage<AnyValue>(&m_arena);
        any_val->set_double_value(val);

        kv->set_allocated_value(any_val);
    }

    void exit_span() {
        Span* span = m_context.top();
        span->set_end_time_unix_nano(_now_unix_nano());

        span->AppendToString(&m_serialized);

        m_context.pop();        
    }

    uint64_t get_serialized_data(const char* buf, uint64_t buf_len) {
        if (buf_len < m_serialized.size()) {
            return 0;
        }

        memcpy((void*)buf, m_serialized.c_str(), m_serialized.size());
        return m_serialized.size();
    }
};

C_API {
    void* lua_resty_protobuf_trace_new();
    void lua_resty_protobuf_trace_free(void* handle);

    void lua_resty_protobuf_trace_enter_span(void* handle, const char* name, uint64_t len);
    void lua_resty_protobuf_trace_add_string_attribute(void* handle, const char* name, uint64_t name_len, const char* val, uint64_t val_len);
    void lua_resty_protobuf_trace_add_bool_attribute(void* handle, const char* name, uint64_t name_len, int32_t val);
    void lua_resty_protobuf_trace_add_int64_attribute(void* handle, const char* name, uint64_t name_len, int64_t val);
    void lua_resty_protobuf_trace_add_double_attribute(void* handle, const char* name, uint64_t name_len, double val);
    void lua_resty_protobuf_trace_exit_span(void* handle);
    uint64_t lua_resty_protobuf_trace_get_serialized(void* handle, const char* buf, uint64_t buf_len);
}

C_API void* lua_resty_protobuf_trace_new() {
    return new Handle();
}

C_API void lua_resty_protobuf_trace_free(void* handle) {
    delete (Handle*)handle;
}

C_API void lua_resty_protobuf_trace_enter_span(void* handle, const char* name, uint64_t len) {
    ((Handle*)handle)->enter_span(name, len);
}

C_API void lua_resty_protobuf_trace_add_string_attribute(void* handle, const char* name, uint64_t name_len, const char* val, uint64_t val_len) {
    ((Handle*)handle)->add_string_attribute(name, name_len, val, val_len);
}

C_API void lua_resty_protobuf_trace_add_bool_attribute(void* handle, const char* name, uint64_t name_len, int32_t val) {
    ((Handle*)handle)->add_bool_attribute(name, name_len, val);
}

C_API void lua_resty_protobuf_trace_add_int64_attribute(void* handle, const char* name, uint64_t name_len, int64_t val) {
    ((Handle*)handle)->add_int64_attribute(name, name_len, val);
}

C_API void lua_resty_protobuf_trace_add_double_attribute(void* handle, const char* name, uint64_t name_len, double val) {
    ((Handle*)handle)->add_double_attribute(name, name_len, val);
}

C_API void lua_resty_protobuf_trace_exit_span(void* handle) {
    ((Handle*)handle)->exit_span();
}

C_API uint64_t lua_resty_protobuf_trace_get_serialized(void* handle, const char* buf, uint64_t buf_len) {
    return ((Handle*)handle)->get_serialized_data(buf, buf_len);
}

