/** 
 * This module defines a set of tools that can be used to profile the
 * performance of your request handler, by wrapping it in a
 * `ProfilingHandler` that emits data to a `ProfilingDataHandler`.
 */
module handy_httpd.handlers.profiling_handler;

import handy_httpd.components.handler;
import handy_httpd.components.request;

import std.container : DList;
import std.algorithm;
import std.datetime;

import slf4d;

/** 
 * The default number of request logs to keep, if no trim policy is specified.
 */
private static const size_t DEFAULT_REQUEST_LOG_MAX_COUNT = 10_000;

/** 
 * Wraps a handler in a ProfilingHandler and returns it.
 * Params:
 *   handler = The handler to wrap in a profiling handler.
 *   dataHandler = The component that'll handle profiling data.
 * Returns: The profiling handler.
 */
public HttpRequestHandler profiled(HttpRequestHandler handler, ProfilingDataHandler dataHandler) {
    return new ProfilingHandler(handler, dataHandler);
}

/** 
 * Wraps a handler in a ProfilingHandler that's using a logging data handler.
 * Params:
 *   handler = The handler to wrap in a profiling handler.
 * Returns: The profiling handler.
 */
public HttpRequestHandler profiled(HttpRequestHandler handler) {
    return profiled(handler, new LoggingProfilingDataHandler());
}

/** 
 * A wrapper handler that can be applied over another, to record performance
 * statistics at runtime. The profiling handler will collect basic information
 * about each request that's handled by a given handler, and pass it on to a
 * data handler. The data handler might write the data to a file, use it for
 * aggregate statistics, or logging.
 */
class ProfilingHandler : HttpRequestHandler {
    private HttpRequestHandler handler;

    private ProfilingDataHandler dataHandler;

    public this(HttpRequestHandler handler, ProfilingDataHandler dataHandler) {
        this.handler = handler;
        this.dataHandler = dataHandler;
    }

    public void handle(ref HttpRequestContext ctx) {
        import std.datetime.stopwatch;
        StopWatch sw = StopWatch(AutoStart.yes);
        try {
            this.handler.handle(ctx);
        } finally {
            sw.stop();
            const RequestInfo info = RequestInfo(
                Clock.currTime(),
                sw.peek(),
                ctx.request.method,
                ctx.response.status
            );
            this.dataHandler.handle(info);
        }
    }
}

/** 
 * A struct containing information about how a request was handled.
 */
struct RequestInfo {
    SysTime timestamp;
    Duration requestDuration;
    Method requestMethod;
    ushort responseStatus;
}

/** 
 * A component that handles profiling data points generated by the ProfilingHandler.
 */
interface ProfilingDataHandler {
    void handle(const ref RequestInfo info);
}

/** 
 * A data handler that occasionally emits profiling data via log messages. You
 * can configure the log level that profiling messages are emitted at, as well
 * as how many requests to cache for aggregate data, and how often to emit a
 * detailed message with aggregate statistics.
 */
class LoggingProfilingDataHandler : ProfilingDataHandler {
    private const size_t cacheMaxSize;
    private DList!RequestInfo cache;
    private size_t cacheSize;

    private Level emitLevel;
    private const size_t detailEmitInterval;
    private size_t requestCount;

    public this(
        Level emitLevel = Levels.INFO,
        const size_t detailEmitInterval = 100,
        const size_t cacheMaxSize = 10_000
    ) {
        this.emitLevel = emitLevel;
        this.detailEmitInterval = detailEmitInterval;
        this.cacheMaxSize = cacheMaxSize;
    }

    void handle(const ref RequestInfo info) {
        logF!"Handled request: Method=%s, Duration=%dms, Response=%d"(
            emitLevel,
            methodToName(info.requestMethod),
            info.requestDuration.total!"msecs",
            info.responseStatus
        );
        synchronized(this) {
            if (cacheSize == cacheMaxSize) {
                cache.removeBack();
                cacheSize--;
            }
            cache.insertFront(info);
            cacheSize++;
            requestCount++;
            if (requestCount == detailEmitInterval) {
                emitDetailedProfilingInfo();
                requestCount = 0;
            }
        }
    }

    private void emitDetailedProfilingInfo() {
        if (cache.empty) return;
        const Duration cacheTimespan = cache.front().timestamp - cache.back().timestamp;
        const double cacheTimespanSeconds = cacheTimespan.total!"hnsecs" / 100_000_000.0;
        const double requestsPerSecond = cacheSize / cacheTimespanSeconds;
        const double averageRequestDurationMs = cache[].map!(info => info.requestDuration.total!"msecs").mean;
        logF!"Profiling Info: Requests per Second=%.3f, Avg Request Duration=%.3fms"(
            emitLevel,
            requestsPerSecond,
            averageRequestDurationMs
        );
    }
}

unittest {
    import handy_httpd.util.builders;
    import slf4d;
    import slf4d.testing_provider;

    shared TestingLoggingProvider provider = new shared TestingLoggingProvider();
    configureLoggingProvider(provider);
    
    LoggingProfilingDataHandler dataHandler = new LoggingProfilingDataHandler();
    ProfilingHandler handler = new ProfilingHandler(toHandler((ref ctx) {
        ctx.response.status = 200;
    }), dataHandler);
    for (int i = 0; i < 10_000; i++) {
        auto ctx = buildCtxForRequest(Method.GET, "/data");
        handler.handle(ctx);
    }
    assert(provider.messageCount == 10_000 + (10_000 / 100));
}

/** 
 * A data handler that saves all request info to a CSV file for later use. Note
 * that the provided file will be overwritten if it already exists.
 */
class CsvProfilingDataHandler : ProfilingDataHandler {
    import std.stdio;

    private File csvFile;

    public this(string filename) {
        this.csvFile = File(filename, "w");
        this.csvFile.writeln("TIMESTAMP, DURATION_HECTONANOSECONDS, REQUEST_METHOD, RESPONSE_STATUS");
        this.csvFile.flush();
    }

    public void handle(const ref RequestInfo info) {
        this.csvFile.writefln!"%s, %d, %s, %d"(
            info.timestamp.toISOExtString(),
            info.requestDuration.total!"hnsecs",
            methodToName(info.requestMethod),
            info.responseStatus
        );
        this.csvFile.flush();
    }

    public void close() {
        this.csvFile.close();
    }
}

unittest {
    import handy_httpd.util.builders;
    import std.file;
    import std.random;
    import std.stdio;
    string csvFile = "tmp-CsvProfilingDataHandler.csv";
    CsvProfilingDataHandler dataHandler = new CsvProfilingDataHandler(csvFile);
    scope(exit) {
        // std.file.remove(csvFile);
    }
    ProfilingHandler handler = new ProfilingHandler(toHandler((ref ctx) {
        ctx.response.status = 200;
    }), dataHandler);
    for (int i = 0; i < 1000; i++) {
        Method method = methodFromIndex(uniform(0, 10));
        auto ctx = buildCtxForRequest(method, "/data");
        handler.handle(ctx);
    }
    dataHandler.close();

    assert(exists(csvFile));
}
