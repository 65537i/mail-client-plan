#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <evntrace.h>
#include <evntcons.h>
#include <tdh.h>
#include <objbase.h>
#include <array>
#include <atomic>
#include <climits>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <vector>

namespace {
constexpr GUID fileProvider = {0xedd08927, 0x9cc4, 0x4e65, {0xb9, 0x70, 0xc2, 0x56, 0x0f, 0xb5, 0xc2, 0x89}};
constexpr wchar_t sessionName[] = L"MailClient-EtwControls-PoC";
constexpr size_t maximumMappings = 128;
constexpr ULONG maximumEvents = 200000;
constexpr ULONGLONG maximumDurationMs = 10000;
enum class Target { other, control, canary };
enum class Operation { create, read, query };
struct Failure { const char* stage; };
void Require(bool condition, const char* stage) { if (!condition) throw Failure{stage}; }

struct Record {
    USHORT id;
    ULONGLONG object;
    ULONGLONG key;
    Target target = Target::other;
};

struct Model {
    std::map<ULONGLONG, Target> objects;
    std::map<ULONGLONG, Target> keys;
    std::array<std::array<ULONG, 3>, 2> counts{};

    void Bind(std::map<ULONGLONG, Target>& table, ULONGLONG value, Target target) {
        Require(value != 0 || target == Target::other, "zero-correlation");
        table.erase(value);
        if (target != Target::other) {
            Require(objects.size() + keys.size() < maximumMappings, "mapping-limit");
            table.emplace(value, target);
        }
    }

    void Count(Target target, Operation operation) {
        if (target == Target::other) return;
        auto& value = counts[target == Target::control ? 0 : 1][static_cast<size_t>(operation)];
        Require(value < maximumEvents, "count-limit");
        ++value;
    }

    void Observe(const Record& event) {
        if (event.id == 10) { Bind(keys, event.key, event.target); return; }
        if (event.id == 11) { keys.erase(event.key); return; }
        if (event.id == 12) {
            Bind(objects, event.object, event.target);
            Count(event.target, Operation::create);
            return;
        }
        if (event.id == 14) { objects.erase(event.object); return; }
        if (event.id != 15 && event.id != 22) return;
        const auto object = objects.find(event.object);
        const auto key = keys.find(event.key);
        const Target byObject = object == objects.end() ? Target::other : object->second;
        const Target byKey = key == keys.end() ? Target::other : key->second;
        Require(byObject == Target::other || byKey == Target::other || byObject == byKey, "correlation-conflict");
        Count(byObject != Target::other ? byObject : byKey,
            event.id == 15 ? Operation::read : Operation::query);
    }

    bool ControlReady() const {
        return counts[0][0] > 0 && counts[0][1] > 0 && counts[0][2] > 0;
    }

    bool CanaryObserved() const {
        return counts[1][0] > 0 || counts[1][1] > 0 || counts[1][2] > 0;
    }

    bool CanaryComplete() const {
        return counts[1][0] > 0 && counts[1][1] > 0 && counts[1][2] > 0;
    }
};

int Evaluate(const Model& model, bool touchCanary) {
    Require(model.ControlReady(), "control-missing");
    Require(model.CanaryObserved() == touchCanary, "canary-expectation");
    Require(!touchCanary || model.CanaryComplete(), "canary-operation-missing");
    return model.CanaryObserved() ? 2 : 0;
}

bool Lossless(ULONG events, ULONG loggedBuffers, ULONG realtimeBuffers) {
    return events == 0 && loggedBuffers == 0 && realtimeBuffers == 0;
}

void CheckVersion(USHORT id, UCHAR version) {
    Require(version <= ((id == 10 || id == 11) ? 0 : 1), "event-version");
}

bool SamePath(const std::wstring& left, const std::wstring& right) {
    return CompareStringOrdinal(left.c_str(), -1, right.c_str(), -1, TRUE) == CSTR_EQUAL;
}

ULONGLONG DecodePointer(const std::vector<BYTE>& bytes) {
    Require(bytes.size() == 4 || bytes.size() == 8, "pointer-shape");
    ULONGLONG result = 0;
    memcpy(&result, bytes.data(), bytes.size());
    return result;
}

std::wstring DecodePath(const std::vector<BYTE>& bytes) {
    Require(bytes.size() >= sizeof(wchar_t) && bytes.size() <= 8192 &&
        bytes.size() % sizeof(wchar_t) == 0, "path-shape");
    std::wstring value(bytes.size() / sizeof(wchar_t), L'\0');
    memcpy(value.data(), bytes.data(), bytes.size());
    Require(value.back() == L'\0', "path-termination");
    value.pop_back();
    Require(value.find(L'\0') == std::wstring::npos, "path-termination");
    return value;
}

std::vector<BYTE> Property(PEVENT_RECORD event, const wchar_t* name) {
    PROPERTY_DATA_DESCRIPTOR descriptor{};
    descriptor.PropertyName = reinterpret_cast<ULONGLONG>(name);
    descriptor.ArrayIndex = ULONG_MAX;
    ULONG size = 0;
    Require(TdhGetPropertySize(event, 0, nullptr, 1, &descriptor, &size) == ERROR_SUCCESS &&
        size > 0 && size <= 8192, "property-size");
    std::vector<BYTE> bytes(size);
    Require(TdhGetProperty(event, 0, nullptr, 1, &descriptor, size, bytes.data()) == ERROR_SUCCESS,
        "property-decode");
    return bytes;
}

struct Files {
    std::wstring directory;
    std::array<std::wstring, 3> paths;
    std::array<std::wstring, 2> devicePaths;
    bool removed = false;

    void Prepare() {
        std::array<wchar_t, 32768> temporary{};
        const DWORD length = GetTempPathW(static_cast<DWORD>(temporary.size()), temporary.data());
        Require(length > 0 && length < temporary.size(), "temporary-directory");
        GUID id{};
        Require(SUCCEEDED(CoCreateGuid(&id)), "temporary-identity");
        std::array<wchar_t, 40> identifier{};
        Require(StringFromGUID2(id, identifier.data(), static_cast<int>(identifier.size())) > 0,
            "temporary-identity");
        directory = std::wstring(temporary.data()) + L"mail-client-etw-controls-" + identifier.data();
        Require(CreateDirectoryW(directory.c_str(), nullptr) != FALSE, "temporary-directory");
        paths = {directory + L"\\control.bin", directory + L"\\canary.bin", directory + L"\\excluded.bin"};
        for (const auto& path : paths) {
            HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW,
                FILE_ATTRIBUTE_NORMAL, nullptr);
            Require(file != INVALID_HANDLE_VALUE, "fixture-create");
            DWORD written = 0;
            const BYTE contents[] = {0x45, 0x54, 0x57, 0x01};
            const bool success = WriteFile(file, contents, sizeof(contents), &written, nullptr) &&
                written == sizeof(contents) && FlushFileBuffers(file);
            const bool closed = CloseHandle(file) != FALSE;
            Require(success && closed, "fixture-write");
        }
        Require(paths[0].size() > 3 && paths[0][1] == L':' && paths[0][2] == L'\\',
            "local-drive-required");
        const std::wstring drive = paths[0].substr(0, 2);
        std::array<wchar_t, 32768> device{};
        Require(QueryDosDeviceW(drive.c_str(), device.data(), static_cast<DWORD>(device.size())) > 0,
            "device-path");
        for (size_t index = 0; index < devicePaths.size(); ++index)
            devicePaths[index] = std::wstring(device.data()) + paths[index].substr(2);
    }

    Target Classify(const std::wstring& path) const {
        for (size_t index = 0; index < devicePaths.size(); ++index)
            if (SamePath(path, devicePaths[index]) || SamePath(path, paths[index]))
                return index == 0 ? Target::control : Target::canary;
        return Target::other;
    }

    bool Cleanup() {
        bool success = true;
        for (const auto& path : paths)
            if (!path.empty() && !DeleteFileW(path.c_str()) && GetLastError() != ERROR_FILE_NOT_FOUND)
                success = false;
        if (!directory.empty() && !RemoveDirectoryW(directory.c_str())) success = false;
        removed = success;
        return success;
    }

    ~Files() {
        if (!removed && !Cleanup()) std::fputs("ETW_CONTROLS_ERROR=fixture-cleanup\n", stderr);
    }
};

struct Properties {
    EVENT_TRACE_PROPERTIES data{};
    wchar_t name[128]{};
    Properties() {
        data.Wnode.BufferSize = sizeof(*this);
        data.Wnode.Flags = WNODE_FLAG_TRACED_GUID;
        data.Wnode.ClientContext = 1;
        data.LoggerNameOffset = offsetof(Properties, name);
        data.BufferSize = 64;
        data.MinimumBuffers = 16;
        data.MaximumBuffers = 64;
        data.FlushTimer = 1;
        data.LogFileMode = EVENT_TRACE_REAL_TIME_MODE;
        // No LogFileNameOffset: unrelated event payloads must never be written to ETL.
    }
};

struct Consumer {
    const Files& files;
    Model model;
    std::mutex mutex;
    std::atomic<const char*> error{nullptr};
    std::atomic<ULONG> received{0};
    std::atomic<ULONG> processResult{ERROR_SUCCESS};
    TRACEHANDLE session = 0;
    TRACEHANDLE trace = INVALID_PROCESSTRACE_HANDLE;
    HANDLE worker = nullptr;
    ULONGLONG deadline = 0;
    bool stopped = false;

    explicit Consumer(const Files& input) : files(input) {}

    static void WINAPI OnEvent(PEVENT_RECORD event) noexcept {
        auto& self = *static_cast<Consumer*>(event->UserContext);
        if (self.error.load() != nullptr) return;
        try {
            Require(GetTickCount64() < self.deadline, "capture-deadline");
            Require(self.received.fetch_add(1) < maximumEvents, "event-limit");
            if (!IsEqualGUID(event->EventHeader.ProviderId, fileProvider)) return;
            const USHORT id = event->EventHeader.EventDescriptor.Id;
            if (id != 10 && id != 11 && id != 12 && id != 14 && id != 15 && id != 22) return;
            CheckVersion(id, event->EventHeader.EventDescriptor.Version);
            Record record{id, 0, 0};
            if (id == 10 || id == 11) {
                record.key = DecodePointer(Property(event, L"FileKey"));
                record.target = self.files.Classify(DecodePath(Property(event, L"FileName")));
            } else {
                record.object = DecodePointer(Property(event, L"FileObject"));
                if (id == 12)
                    record.target = self.files.Classify(DecodePath(Property(event, L"FileName")));
                else if (id == 15 || id == 22)
                    record.key = DecodePointer(Property(event, L"FileKey"));
            }
            std::lock_guard<std::mutex> lock(self.mutex);
            self.model.Observe(record);
        } catch (const Failure& failure) {
            self.error.store(failure.stage);
        } catch (...) {
            self.error.store("consumer-exception");
        }
    }

    static ULONG WINAPI OnBuffer(PEVENT_TRACE_LOGFILEW log) noexcept {
        auto& self = *static_cast<Consumer*>(log->Context);
        if (log->EventsLost != 0) self.error.store("consumer-loss");
        return TRUE;
    }

    static DWORD WINAPI Process(void* context) {
        auto& self = *static_cast<Consumer*>(context);
        self.processResult.store(ProcessTrace(&self.trace, 1, nullptr, nullptr));
        return 0;
    }

    void Start() {
        deadline = GetTickCount64() + maximumDurationMs;
        Properties properties;
        const ULONG started = StartTraceW(&session, sessionName, &properties.data);
        if (started != ERROR_SUCCESS) {
            session = 0;
            throw Failure{started == ERROR_ALREADY_EXISTS ? "session-already-exists" : "session-start"};
        }
        Require(properties.data.MaximumBuffers <= 64 && properties.data.BufferSize <= 64,
            "session-resource-limit");
        Properties actual;
        Require(ControlTraceW(session, nullptr, &actual.data, EVENT_TRACE_CONTROL_QUERY) == ERROR_SUCCESS,
            "session-query");
        Require(actual.data.MaximumBuffers <= 64 && actual.data.NumberOfBuffers <= 64 &&
            actual.data.BufferSize <= 64, "session-resource-limit");
        Require(Lossless(actual.data.EventsLost, actual.data.LogBuffersLost,
            actual.data.RealTimeBuffersLost), "trace-loss");
        EVENT_TRACE_LOGFILEW logfile{};
        logfile.LoggerName = const_cast<LPWSTR>(sessionName);
        logfile.ProcessTraceMode = PROCESS_TRACE_MODE_REAL_TIME | PROCESS_TRACE_MODE_EVENT_RECORD;
        logfile.EventRecordCallback = OnEvent;
        logfile.BufferCallback = OnBuffer;
        logfile.Context = this;
        trace = OpenTraceW(&logfile);
        Require(trace != INVALID_PROCESSTRACE_HANDLE, "consumer-open");
        worker = CreateThread(nullptr, 0, Process, this, 0, nullptr);
        Require(worker != nullptr, "consumer-start");
        ENABLE_TRACE_PARAMETERS parameters{};
        parameters.Version = ENABLE_TRACE_PARAMETERS_VERSION_2;
        Require(EnableTraceEx2(session, &fileProvider, EVENT_CONTROL_CODE_ENABLE_PROVIDER,
            TRACE_LEVEL_INFORMATION, 0x1F0, 0, 1000, &parameters) == ERROR_SUCCESS, "provider-enable");
    }

    Model Snapshot() {
        const char* failure = error.load();
        Require(failure == nullptr, failure);
        Require(GetTickCount64() < deadline, "capture-deadline");
        Require(worker != nullptr && WaitForSingleObject(worker, 0) == WAIT_TIMEOUT, "consumer-ended");
        std::lock_guard<std::mutex> lock(mutex);
        return model;
    }

    bool Stop() {
        if (stopped) return true;
        stopped = true;
        bool success = true;
        if (session != 0) {
            Properties properties;
            if (ControlTraceW(session, nullptr, &properties.data, EVENT_TRACE_CONTROL_STOP) != ERROR_SUCCESS)
                success = false;
            else if (!Lossless(properties.data.EventsLost, properties.data.LogBuffersLost,
                properties.data.RealTimeBuffersLost))
                success = false;
            session = 0;
        }
        // A stopped real-time session is drained by ProcessTrace before closing the consumer.
        if (worker != nullptr && success && WaitForSingleObject(worker, 3000) != WAIT_OBJECT_0)
            success = false;
        if (trace != INVALID_PROCESSTRACE_HANDLE) {
            if (CloseTrace(trace) != ERROR_SUCCESS) success = false;
        }
        if (worker != nullptr) {
            if (WaitForSingleObject(worker, 5000) != WAIT_OBJECT_0) {
                std::fputs("ETW_CONTROLS_ERROR=consumer-cleanup-timeout\n", stderr);
                std::_Exit(1);
            }
            if (!CloseHandle(worker)) success = false;
            worker = nullptr;
            const ULONG result = processResult.load();
            if (result != ERROR_SUCCESS && result != ERROR_CANCELLED) success = false;
        }
        trace = INVALID_PROCESSTRACE_HANDLE;
        return success;
    }

    ~Consumer() {
        if (!stopped && !Stop()) std::fputs("ETW_CONTROLS_ERROR=session-cleanup\n", stderr);
    }
};

void Exercise(const std::wstring& path) {
    HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE |
        FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    Require(file != INVALID_HANDLE_VALUE, "control-open");
    BYTE bytes[4]{};
    DWORD read = 0;
    BY_HANDLE_FILE_INFORMATION information{};
    const bool success = ReadFile(file, bytes, sizeof(bytes), &read, nullptr) && read == sizeof(bytes) &&
        GetFileInformationByHandle(file, &information);
    const bool closed = CloseHandle(file) != FALSE;
    Require(success && closed, "control-operation");
}

int Capture(bool touchCanary) {
    Files files;
    files.Prepare();
    Consumer consumer(files);
    consumer.Start();
    // Positive events, not just EnableTraceEx2 success, establish the consumer-ready barrier.
    const ULONGLONG readyDeadline = GetTickCount64() + 3000;
    while (!consumer.Snapshot().ControlReady() && GetTickCount64() < readyDeadline) {
        Exercise(files.paths[0]);
        Sleep(100);
    }
    Require(consumer.Snapshot().ControlReady(), "ready-control-missing");
    Require(!consumer.Snapshot().CanaryObserved(), "early-canary");
    Exercise(files.paths[0]);
    Exercise(files.paths[2]);
    if (touchCanary) Exercise(files.paths[1]);
    const ULONGLONG drainDeadline = GetTickCount64() + 2000;
    while (GetTickCount64() < drainDeadline) {
        if (touchCanary && consumer.Snapshot().CanaryComplete()) break;
        consumer.Snapshot();
        Sleep(50);
    }
    Require(consumer.Stop(), "session-stop-or-loss");
    const char* failure = consumer.error.load();
    Require(failure == nullptr, failure);
    const Model final = consumer.model;
    const int verdict = Evaluate(final, touchCanary);
    Require(files.Cleanup(), "fixture-cleanup");
    std::printf("ETW_CONTROLS_POC=scope:controls-only;scenario:%s;control-create:%lu;"
        "control-read:%lu;control-query:%lu;canary-verdict:%s;loss:zero;cleanup:complete\n",
        touchCanary ? "touched" : "untouched", final.counts[0][0], final.counts[0][1],
        final.counts[0][2], final.CanaryObserved() ? "rejected" : "unobserved");
    return verdict;
}

template<typename Action> void Reject(Action action, const char* expected) {
    try { action(); } catch (const Failure& failure) {
        Require(strcmp(failure.stage, expected) == 0, "fixture-wrong-failure");
        return;
    }
    throw Failure{"fixture-missing-failure"};
}

void SelfTest() {
    Model empty;
    Reject([&] { Evaluate(empty, false); }, "control-missing");
    Model model;
    model.Observe({12, 1, 0, Target::control});
    model.Observe({15, 1, 0});
    model.Observe({22, 1, 0});
    Require(model.ControlReady() && !model.CanaryObserved(), "fixture-positive");
    Require(Evaluate(model, false) == 0, "fixture-untouched-verdict");
    Reject([&] { Evaluate(model, true); }, "canary-expectation");
    model.Observe({12, 2, 0, Target::canary});
    Require(model.CanaryObserved() && !model.CanaryComplete(), "fixture-canary");
    Reject([&] { Evaluate(model, true); }, "canary-operation-missing");
    model.Observe({15, 2, 0});
    model.Observe({22, 2, 0});
    Require(model.CanaryComplete(), "fixture-canary-operations");
    Require(Evaluate(model, true) == 2, "fixture-touched-verdict");
    Reject([&] { Evaluate(model, false); }, "canary-expectation");
    model.Observe({14, 1, 0});
    Require(model.objects.count(1) == 0, "fixture-close");
    model.Observe({12, 2, 0, Target::other});
    Require(model.objects.count(2) == 0, "fixture-reuse");
    model.Observe({10, 0, 3, Target::control});
    model.Observe({15, 99, 3});
    Require(model.counts[0][1] == 2, "fixture-key");
    model.Observe({11, 0, 3});
    Require(model.keys.empty(), "fixture-name-delete");
    model.Observe({12, 4, 0, Target::control});
    model.Observe({10, 0, 5, Target::canary});
    Reject([&] { model.Observe({15, 4, 5}); }, "correlation-conflict");
    Reject([&] { model.Observe({12, 0, 0, Target::control}); }, "zero-correlation");
    model.Observe({12, 0, 0, Target::other});
    Model limit;
    for (ULONGLONG index = 1; index <= maximumMappings; ++index)
        limit.Observe({12, index, 0, Target::control});
    Reject([&] { limit.Observe({12, 129, 0, Target::control}); }, "mapping-limit");
    Require(Lossless(0, 0, 0) && !Lossless(1, 0, 0) && !Lossless(0, 1, 0) &&
        !Lossless(0, 0, 1), "fixture-loss");
    Model countLimit;
    countLimit.counts[0][0] = maximumEvents;
    Reject([&] { countLimit.Observe({12, 1, 0, Target::control}); }, "count-limit");
    CheckVersion(12, 1);
    Reject([] { CheckVersion(12, 2); }, "event-version");
    Reject([] { CheckVersion(10, 1); }, "event-version");
    Require(DecodePointer({1, 0, 0, 0}) == 1 &&
        DecodePointer({1, 0, 0, 0, 0, 0, 0, 0}) == 1 &&
        DecodePointer({0, 0, 0, 0, 1, 0, 0, 0}) == (1ULL << 32), "fixture-pointer");
    Reject([] { DecodePointer({1, 0}); }, "pointer-shape");
    Reject([] { DecodePath({1}); }, "path-shape");
    Reject([] { DecodePath({1, 0}); }, "path-termination");
    Reject([] { DecodePath({0, 0, 1, 0, 0, 0}); }, "path-termination");
    Reject([] { DecodePath(std::vector<BYTE>(8194)); }, "path-shape");
    Require(DecodePath({65, 0, 0, 0}) == L"A", "fixture-path-decode");
    Require(SamePath(L"C:\\CONTROL", L"c:\\control") &&
        !SamePath(L"C:\\control", L"C:\\control-extra"), "fixture-path");
    Files classification;
    classification.removed = true;
    classification.paths = {L"C:\\probe\\control", L"C:\\probe\\canary", L"C:\\probe\\excluded"};
    classification.devicePaths = {L"\\Device\\Probe\\probe\\control", L"\\Device\\Probe\\probe\\canary"};
    Require(classification.Classify(L"\\device\\probe\\probe\\CONTROL") == Target::control &&
        classification.Classify(L"C:\\probe\\canary") == Target::canary &&
        classification.Classify(L"C:\\probe\\excluded") == Target::other &&
        classification.Classify(L"C:\\probe\\canary-extra") == Target::other, "fixture-classification");
    std::puts("ETW_CONTROLS_FIXTURES=passed;capture:not-started");
}
}

int wmain(int argc, wchar_t** argv) {
    try {
        if (argc == 2 && wcscmp(argv[1], L"--self-test") == 0) SelfTest();
        else if (argc == 3 && wcscmp(argv[1], L"--capture-controls") == 0 &&
            (wcscmp(argv[2], L"untouched") == 0 || wcscmp(argv[2], L"touched") == 0))
            return Capture(wcscmp(argv[2], L"touched") == 0);
        else throw Failure{"explicit-mode-required"};
        return 0;
    } catch (const Failure& failure) {
        std::fprintf(stderr, "ETW_CONTROLS_ERROR=%s\n", failure.stage);
    } catch (...) {
        std::fputs("ETW_CONTROLS_ERROR=unexpected-exception\n", stderr);
    }
    return 1;
}
