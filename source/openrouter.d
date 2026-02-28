/// D library to interface with OpenRouter APIs.
/// Uses std.net.curl for HTTP communication, no external dependencies.
module openrouter;

import std.json;
import std.conv : to;
import std.array : appender, join;
import std.string : strip, startsWith, indexOf, representation;
import std.algorithm : map;
import std.format : format;
import std.datetime : SysTime, Clock;
import std.typecons : Nullable, nullable, Tuple;
import std.net.curl;
import std.stdio : File;

// ---------------------------------------------------------------------------
//  Public Types
// ---------------------------------------------------------------------------

/// Roles supported by OpenRouter messages.
enum Role : string
{
    system    = "system",
    user      = "user",
    assistant = "assistant",
    tool      = "tool"
}

/// Multimodal content part (text or image).
struct ContentPart
{
    /// Creates a text part.
    static ContentPart text(string t)
    {
        ContentPart p;
        p.type_ = Type.text;
        p.text_ = t;
        return p;
    }

    /// Creates an image part from URL or base64 data-URI.
    static ContentPart imageUrl(string url, string detail = "auto")
    {
        ContentPart p;
        p.type_ = Type.imageUrl;
        p.text_ = url;
        p.detail_ = detail;
        return p;
    }

    /// Loads an image from local file and converts it to base64 data-URI.
    /// The MIME type is inferred from the extension (.png, .jpg, .jpeg, .gif, .webp).
    static ContentPart imageFile(string path, string detail = "auto")
    {
        import std.file : read;
        import std.base64 : Base64;
        import std.path : extension;
        import std.uni : toLower;

        auto ext = path.extension.toLower;
        string mime;
        switch (ext)
        {
            case ".png":             mime = "image/png"; break;
            case ".jpg": case".jpeg":mime = "image/jpeg"; break;
            case ".gif":             mime = "image/gif"; break;
            case ".webp":            mime = "image/webp"; break;
            default:                 mime = "image/png"; break;
        }

        auto data = cast(ubyte[]) read(path);
        auto encoded = Base64.encode(data);
        string dataUri = "data:" ~ mime ~ ";base64," ~ cast(string) encoded;

        return imageUrl(dataUri, detail);
    }

    private enum Type { text, imageUrl }
    private Type type_;
    private string text_;
    private string detail_ = "auto";

    package JSONValue toJson() const
    {
        JSONValue j;
        final switch (type_)
        {
            case Type.text:
                j["type"] = "text";
                j["text"] = text_;
                break;
            case Type.imageUrl:
                j["type"] = "image_url";
                JSONValue inner;
                inner["url"] = text_;
                inner["detail"] = detail_;
                j["image_url"] = inner;
                break;
        }
        return j;
    }
}

/// A single message in the conversation.
struct Message
{
    Role role;
    /// Simple text content (null if using `parts`).
    Nullable!string content;
    /// Multimodal content (images + text).
    ContentPart[] parts;
    /// Optional: author name.
    Nullable!string name;
    /// Required for role == Role.tool.
    Nullable!string toolCallId;

    package JSONValue toJson() const
    {
        JSONValue j;
        j["role"] = role;

        if (parts.length > 0)
        {
            JSONValue[] arr;
            foreach (ref p; parts)
                arr ~= p.toJson();
            j["content"] = JSONValue(arr);
        }
        else if (!content.isNull)
        {
            j["content"] = content.get;
        }

        if (!name.isNull)
            j["name"] = name.get;
        if (!toolCallId.isNull)
            j["tool_call_id"] = toolCallId.get;

        return j;
    }
}

/// Token usage statistics returned in the response.
struct Usage
{
    int promptTokens;
    int completionTokens;
    int totalTokens;
    Nullable!double cost;

    string toString() const
    {
        auto s = format!"prompt=%d completion=%d total=%d"(
            promptTokens, completionTokens, totalTokens);
        if (!cost.isNull)
            s ~= format!" cost=%.6f"(cost.get);
        return s;
    }
}

/// Information about a tool call received from the model.
struct ToolCall
{
    string id;
    string functionName;
    string functionArguments; // Raw JSON
}

/// Image generated and returned by the model (base64 data-URI or URL).
struct ImageData
{
    string url; // "data:image/png;base64,..." or http URL

    /// Checks if this is a data-URI (base64 encoded).
    bool isDataUri() const
    {
        import std.string : startsWith;
        return url.startsWith("data:");
    }

    /// Checks if this is a remote URL.
    bool isRemoteUrl() const
    {
        return !isDataUri();
    }

    /// Decodes and returns the image bytes from base64 data-URI.
    /// Returns null if it's a remote URL (use save() to download it).
    ubyte[] decodeBase64() const
    {
        import std.base64 : Base64;
        import std.string : indexOf;
        auto commaPos = url.indexOf(',');
        if (commaPos < 0) return null;
        auto encoded = url[commaPos + 1 .. $];
        try
            return Base64.decode(encoded);
        catch (Exception)
            return null;
    }

    /// Saves the image to disk. For data-URI, saves with a UUID filename.
    /// For remote URLs, downloads and saves. Returns the absolute file path.
    string save(string outputDir = ".") const
    {
        import std.file : write, mkdirRecurse;
        import std.path : buildPath, extension;
        import std.uuid : randomUUID;
        import std.net.curl : get;

        // Create output directory if needed
        mkdirRecurse(outputDir);

        string filePath;
        ubyte[] imageBytes;

        if (isDataUri())
        {
            // Decode base64 data-URI
            imageBytes = decodeBase64();
            if (imageBytes is null || imageBytes.length == 0)
                throw new Exception("Failed to decode base64 data-URI");

            // Determine extension from MIME type
            import std.string : indexOf;
            auto mimeStart = url.indexOf(':') + 1;
            auto mimeEnd = url.indexOf(';', mimeStart);
            if (mimeEnd < 0) mimeEnd = url.indexOf(',', mimeStart);
            string mime = url[mimeStart .. mimeEnd];

            string ext = ".png"; // default
            if (mime.indexOf("jpeg") >= 0 || mime.indexOf("jpg") >= 0)
                ext = ".jpg";
            else if (mime.indexOf("gif") >= 0)
                ext = ".gif";
            else if (mime.indexOf("webp") >= 0)
                ext = ".webp";

            // Generate UUID filename
            string filename = randomUUID().toString() ~ ext;
            filePath = buildPath(outputDir, filename);
        }
        else
        {
            // Download remote URL
            imageBytes = cast(ubyte[]) get(url);

            // Extract filename from URL or generate UUID
            import std.string : lastIndexOf;
            auto lastSlash = url.lastIndexOf('/');
            string filename;
            if (lastSlash >= 0 && lastSlash < url.length - 1)
            {
                filename = url[lastSlash + 1 .. $];
                // Remove query parameters
                auto qPos = filename.indexOf('?');
                if (qPos >= 0)
                    filename = filename[0 .. qPos];
            }
            if (filename.length == 0)
            {
                // No filename in URL, generate UUID
                filename = randomUUID().toString() ~ ".png";
            }

            filePath = buildPath(outputDir, filename);
        }

        write(filePath, imageBytes);
        return filePath;
    }
}

/// A single choice in the response (non-streaming).
struct Choice
{
    Nullable!string finishReason;
    Nullable!string nativeFinishReason;
    Nullable!string content;
    ToolCall[] toolCalls;
    ImageData[] images; // Generated images (message.images field)

    /// Text content, empty string if null.
    string text() const { return content.isNull ? "" : content.get; }
}

/// Complete response from a non-streaming request.
struct Response
{
    string id;
    string model;
    string object_;  // "chat.completion"
    long created;
    Choice[] choices;
    Usage usage;

    /// Text of the first choice (common shortcut).
    string text() const
    {
        return choices.length > 0 ? choices[0].text : "";
    }

    /// Finish reason of the first choice.
    string finishReason() const
    {
        if (choices.length == 0) return "";
        return choices[0].finishReason.isNull ? "" : choices[0].finishReason.get;
    }

    /// Generated images from the first choice.
    const(ImageData)[] images() const
    {
        return choices.length > 0 ? choices[0].images : null;
    }
}

/// Chunk received during SSE streaming.
struct StreamChunk
{
    string id;
    string model;
    long created;
    Nullable!string content;  // delta.content
    Nullable!string finishReason;
    Usage usage; // populated only in the last chunk

    /// Text of the delta, empty string if null.
    string text() const { return content.isNull ? "" : content.get; }
}

/// Error returned by the API.
class OpenRouterException : Exception
{
    int code;
    string details;

    this(int code, string msg, string details = null)
    {
        super(msg);
        this.code = code;
        this.details = details;
    }
}

// ---------------------------------------------------------------------------
//  Main Client
// ---------------------------------------------------------------------------

/// Client for OpenRouter chat completions API.
struct OpenRouter
{
    private string apiKey_;
    private string model_;
    private Message[] messages_;

    // Optional LLM parameters
    private Nullable!int maxTokens_;
    private Nullable!double temperature_;
    private Nullable!double topP_;
    private Nullable!int topK_;
    private Nullable!double frequencyPenalty_;
    private Nullable!double presencePenalty_;
    private Nullable!double repetitionPenalty_;
    private Nullable!int seed_;

    // Optional headers
    private string referer_;
    private string title_;

    // Response format
    private Nullable!string responseFormatType_; // "json_object" or "json_schema"
    private Nullable!string jsonSchemaName_;
    private Nullable!string jsonSchemaBody_; // Raw JSON schema

    // Modalities (for image generation: ["text", "image"])
    private string[] modalities_;

    // Preconfigured system prompt
    private Nullable!string systemPrompt_;

    /// Constructor. `model` defaults to "openrouter/free".
    this(string apiKey, string model = "openrouter/free")
    {
        apiKey_ = apiKey;
        model_ = model;
    }

    // -- Fluent Configuration ------------------------------------------------

    /// Sets the model to use.
    ref OpenRouter setModel(string m) return { model_ = m; return this; }

    /// Sets the system prompt (will be prepended as the first message).
    ref OpenRouter setSystemPrompt(string s) return { systemPrompt_ = s; return this; }

    ref OpenRouter setMaxTokens(int v) return { maxTokens_ = v; return this; }
    ref OpenRouter setTemperature(double v) return { temperature_ = v; return this; }
    ref OpenRouter setTopP(double v) return { topP_ = v; return this; }
    ref OpenRouter setTopK(int v) return { topK_ = v; return this; }
    ref OpenRouter setFrequencyPenalty(double v) return { frequencyPenalty_ = v; return this; }
    ref OpenRouter setPresencePenalty(double v) return { presencePenalty_ = v; return this; }
    ref OpenRouter setRepetitionPenalty(double v) return { repetitionPenalty_ = v; return this; }
    ref OpenRouter setSeed(int v) return { seed_ = v; return this; }

    /// Sets the output modalities (e.g. ["text", "image"] for image generation).
    ref OpenRouter setModalities(string[] m) return { modalities_ = m; return this; }

    /// HTTP-Referer header to identify the application.
    ref OpenRouter setReferer(string r) return { referer_ = r; return this; }
    /// X-OpenRouter-Title header.
    ref OpenRouter setTitle(string t) return { title_ = t; return this; }

    /// Request free JSON output (without schema).
    ref OpenRouter setJsonMode() return
    {
        responseFormatType_ = "json_object";
        jsonSchemaName_ = Nullable!string.init;
        jsonSchemaBody_ = Nullable!string.init;
        return this;
    }

    /// Request output conforming to a JSON schema.
    ref OpenRouter setJsonSchema(string name, string schemaJson) return
    {
        responseFormatType_ = "json_schema";
        jsonSchemaName_ = name;
        jsonSchemaBody_ = schemaJson;
        return this;
    }

    /// Disables forced response format.
    ref OpenRouter clearResponseFormat() return
    {
        responseFormatType_ = Nullable!string.init;
        jsonSchemaName_ = Nullable!string.init;
        jsonSchemaBody_ = Nullable!string.init;
        return this;
    }

    // -- Message Management -------------------------------------------------

    /// Adds a text message to the conversation.
    ref OpenRouter addMessage(string content, Role role = Role.user) return
    {
        Message m;
        m.role = role;
        m.content = content;
        messages_ ~= m;
        return this;
    }

    /// Adds a multimodal message (text + images).
    ref OpenRouter addMessage(ContentPart[] parts, Role role = Role.user) return
    {
        Message m;
        m.role = role;
        m.parts = parts;
        messages_ ~= m;
        return this;
    }

    /// Adds a message from a prebuilt Message object.
    ref OpenRouter addMessage(Message m) return
    {
        messages_ ~= m;
        return this;
    }

    /// Overwrites all messages with a single one.
    ref OpenRouter setMessage(string content, Role role = Role.user) return
    {
        messages_.length = 0;
        return addMessage(content, role);
    }

    /// Overwrites all messages.
    ref OpenRouter setMessages(Message[] msgs) return
    {
        messages_ = msgs.dup;
        return this;
    }

    /// Returns current messages (read-only).
    const(Message)[] messages() const { return messages_; }

    /// Clears the message history.
    ref OpenRouter clear() return
    {
        messages_.length = 0;
        return this;
    }

    // -- Request Sending --------------------------------------------------

    /// Sends the request and returns the complete response.
    Response complete()
    {
        auto body_ = buildRequestBody(false);
        auto raw = doPost(body_);
        return parseResponse(raw);
    }

    /// Sends the request with streaming. Invokes `onChunk` for each delta received.
    /// Returns the generation id and final usage.
    Tuple!(string, "id", Usage, "usage") stream(scope void delegate(string text) onChunk)
    {
        return streamImpl(onChunk, null);
    }

    /// Streaming version with callback for complete chunk (access to finishReason etc.).
    Tuple!(string, "id", Usage, "usage") streamFull(scope void delegate(StreamChunk chunk) onChunk)
    {
        return streamImpl(null, onChunk);
    }

    // -- Public Utilities --------------------------------------------------

    /// Adds the assistant's response to the conversation (for multi-turn).
    ref OpenRouter addResponse(Response resp) return
    {
        if (resp.choices.length > 0 && !resp.choices[0].content.isNull)
            addMessage(resp.choices[0].content.get, Role.assistant);
        return this;
    }

    /// Current model.
    string model() const { return model_; }

    /// Downloads a file from a URL and saves it to disk. Useful for saving
    /// generated images. Returns the absolute path of the saved file.
    static string download(string url, string destPath)
    {
        import std.net.curl : download;
        download(url, destPath);
        return destPath;
    }

    // -----------------------------------------------------------------------
    //  Private Implementation
    // -----------------------------------------------------------------------

    private:

    /// Builds the JSON request body.
    string buildRequestBody(bool streaming)
    {
        JSONValue req;
        req["model"] = model_;
        req["stream"] = streaming;

        // Messages: prepend system prompt if present
        JSONValue[] msgArr;
        if (!systemPrompt_.isNull)
        {
            JSONValue sysMsg;
            sysMsg["role"] = "system";
            sysMsg["content"] = systemPrompt_.get;
            msgArr ~= sysMsg;
        }
        foreach (ref m; messages_)
            msgArr ~= m.toJson();
        req["messages"] = JSONValue(msgArr);

        // Optional LLM parameters
        if (!maxTokens_.isNull)       req["max_tokens"]        = maxTokens_.get;
        if (!temperature_.isNull)     req["temperature"]       = temperature_.get;
        if (!topP_.isNull)            req["top_p"]             = topP_.get;
        if (!topK_.isNull)            req["top_k"]             = topK_.get;
        if (!frequencyPenalty_.isNull) req["frequency_penalty"] = frequencyPenalty_.get;
        if (!presencePenalty_.isNull)  req["presence_penalty"]  = presencePenalty_.get;
        if (!repetitionPenalty_.isNull)req["repetition_penalty"]= repetitionPenalty_.get;
        if (!seed_.isNull)            req["seed"]              = seed_.get;

        // Modalities (for image generation)
        if (modalities_.length > 0)
        {
            JSONValue[] mods;
            foreach (m; modalities_)
                mods ~= JSONValue(m);
            req["modalities"] = JSONValue(mods);
        }

        // Response format
        if (!responseFormatType_.isNull)
        {
            JSONValue rf;
            rf["type"] = responseFormatType_.get;
            if (responseFormatType_.get == "json_schema"
                && !jsonSchemaName_.isNull && !jsonSchemaBody_.isNull)
            {
                JSONValue js;
                js["name"] = jsonSchemaName_.get;
                js["schema"] = parseJSON(jsonSchemaBody_.get);
                rf["json_schema"] = js;
            }
            req["response_format"] = rf;
        }

        return req.toString();
    }

    /// Common HTTP headers for all requests.
    string[] commonHeaders()
    {
        string[] h = [
            "Authorization: Bearer " ~ apiKey_,
            "Content-Type: application/json"
        ];
        if (referer_.length > 0) h ~= "HTTP-Referer: " ~ referer_;
        if (title_.length > 0)   h ~= "X-OpenRouter-Title: " ~ title_;
        return h;
    }

    /// Synchronous POST via std.net.curl. Returns the response body.
    string doPost(string requestBody)
    {
        auto http = HTTP();
        http.url = "https://openrouter.ai/api/v1/chat/completions";

        foreach (h; commonHeaders())
        {
            auto idx = h.indexOf(':');
            if (idx > 0)
                http.addRequestHeader(h[0 .. idx], h[idx + 1 .. $].strip);
        }

        http.method = HTTP.Method.post;
        http.setPostData(requestBody, "application/json");

        auto responseBuf = appender!string;
        http.onReceive = (ubyte[] data) {
            responseBuf ~= cast(const(char)[]) data;
            return data.length;
        };

        http.perform();

        auto code = http.statusLine.code;
        auto raw = responseBuf[];

        // HTTP errors pre-stream (4xx, 5xx)
        if (code >= 400)
        {
            string msg = format!"HTTP %d"(code);
            string details;
            try
            {
                auto ej = parseJSON(raw);
                if ("error" in ej)
                {
                    auto err = ej["error"];
                    if ("message" in err) msg = err["message"].str;
                    details = err.toString();
                }
            }
            catch (Exception) {}
            throw new OpenRouterException(code, msg, details);
        }

        return raw;
    }

    /// Parsing of complete JSON response.
    static Response parseResponse(string raw)
    {
        auto j = parseJSON(raw);

        // Check for error in body even with HTTP 200
        if ("error" in j)
            throwFromErrorObject(j["error"]);

        Response r;
        r.id = ("id" in j) ? j["id"].str : "";
        r.model = ("model" in j) ? j["model"].str : "";
        r.object_ = ("object" in j) ? j["object"].str : "";
        r.created = ("created" in j) ? j["created"].integer : 0;

        if ("usage" in j)
            r.usage = parseUsage(j["usage"]);

        if ("choices" in j)
        {
            foreach (ref cj; j["choices"].array)
            {
                Choice c;
                if ("finish_reason" in cj && cj["finish_reason"].type != JSONType.null_)
                    c.finishReason = cj["finish_reason"].str;
                if ("native_finish_reason" in cj && cj["native_finish_reason"].type != JSONType.null_)
                    c.nativeFinishReason = cj["native_finish_reason"].str;

                // Error inside choice (e.g. provider error with HTTP 200)
                if ("error" in cj)
                    throwFromErrorObject(cj["error"]);

                if ("message" in cj)
                {
                    auto msg = cj["message"];
                    if ("content" in msg && msg["content"].type != JSONType.null_)
                        c.content = msg["content"].str;
                    if ("tool_calls" in msg)
                        c.toolCalls = parseToolCalls(msg["tool_calls"]);
                    // Generated images (base64 data-URI)
                    if ("images" in msg)
                        c.images = parseImages(msg["images"]);
                }
                r.choices ~= c;
            }
        }

        return r;
    }

    /// Streaming implementation: reads SSE via curl, invokes callbacks.
    Tuple!(string, "id", Usage, "usage") streamImpl(
        scope void delegate(string) onText,
        scope void delegate(StreamChunk) onFull)
    {
        auto body_ = buildRequestBody(true);

        auto http = HTTP();
        http.url = "https://openrouter.ai/api/v1/chat/completions";

        foreach (h; commonHeaders())
        {
            auto idx = h.indexOf(':');
            if (idx > 0)
                http.addRequestHeader(h[0 .. idx], h[idx + 1 .. $].strip);
        }

        http.method = HTTP.Method.post;
        http.setPostData(body_, "application/json");

        string generationId;
        Usage finalUsage;
        string lineBuf;

        http.onReceive = (ubyte[] data) {
            lineBuf ~= cast(const(char)[]) data;

            // Process complete lines in the buffer
            while (true)
            {
                auto nlPos = lineBuf.indexOf('\n');
                if (nlPos < 0) break;

                auto line = lineBuf[0 .. nlPos].strip;
                lineBuf = lineBuf[nlPos + 1 .. $];

                // Ignore empty lines and SSE comments (keepalive)
                if (line.length == 0 || line.startsWith(":"))
                    continue;

                // Remove "data: " prefix
                if (!line.startsWith("data: ") && !line.startsWith("data:"))
                    continue;
                auto payload = line.startsWith("data: ") ? line[6 .. $] : line[5 .. $];
                payload = payload.strip;

                if (payload == "[DONE]")
                    continue;

                try
                {
                    auto cj = parseJSON(payload);

                    // Mid-stream error
                    if ("error" in cj)
                    {
                        auto err = cj["error"];
                        int code = 0;
                        string msg = "Stream error";
                        if ("code" in err)
                        {
                            auto cv = err["code"];
                            if (cv.type == JSONType.integer)
                                code = cv.integer.to!int;
                            else if (cv.type == JSONType.string)
                                msg = cv.str;
                        }
                        if ("message" in err)
                            msg = err["message"].str;
                        throw new OpenRouterException(code, msg);
                    }

                    StreamChunk chunk;
                    chunk.id = ("id" in cj) ? cj["id"].str : "";
                    chunk.model = ("model" in cj) ? cj["model"].str : "";
                    chunk.created = ("created" in cj) ? cj["created"].integer : 0;

                    if (chunk.id.length > 0)
                        generationId = chunk.id;

                    // Usage in the last chunk
                    if ("usage" in cj && cj["usage"].type != JSONType.null_)
                    {
                        finalUsage = parseUsage(cj["usage"]);
                        chunk.usage = finalUsage;
                    }

                    // Delta content
                    if ("choices" in cj)
                    {
                        foreach (ref choice; cj["choices"].array)
                        {
                            if ("delta" in choice)
                            {
                                auto delta = choice["delta"];
                                if ("content" in delta && delta["content"].type != JSONType.null_)
                                    chunk.content = delta["content"].str;
                            }
                            if ("finish_reason" in choice && choice["finish_reason"].type != JSONType.null_)
                                chunk.finishReason = choice["finish_reason"].str;
                        }
                    }

                    // Invoke callbacks
                    if (onText !is null && !chunk.content.isNull)
                        onText(chunk.content.get);
                    if (onFull !is null)
                        onFull(chunk);
                }
                catch (OpenRouterException e)
                    throw e;
                catch (Exception)
                {
                    // Malformed chunk JSON: ignore
                }
            }

            return data.length;
        };

        // Check for HTTP errors before streaming
        ushort statusCode;
        http.onReceiveStatusLine = (HTTP.StatusLine sl) {
            statusCode = sl.code;
        };

        http.perform();

        // If HTTP code indicates error and we haven't thrown yet
        if (statusCode >= 400)
        {
            // The error might have been processed in buffer,
            // but if it arrived as complete body we try to parse it
            if (lineBuf.strip.length > 0)
            {
                try
                {
                    auto ej = parseJSON(lineBuf.strip);
                    if ("error" in ej)
                    {
                        auto err = ej["error"];
                        string msg = ("message" in err) ? err["message"].str : "HTTP error";
                        throw new OpenRouterException(statusCode, msg);
                    }
                }
                catch (OpenRouterException e) throw e;
                catch (Exception) {}
            }
            throw new OpenRouterException(statusCode, format!"HTTP %d"(statusCode));
        }

        return typeof(return)(generationId, finalUsage);
    }

    /// Parsing of usage object.
    static Usage parseUsage(JSONValue j)
    {
        Usage u;
        if ("prompt_tokens" in j)     u.promptTokens     = j["prompt_tokens"].integer.to!int;
        if ("completion_tokens" in j) u.completionTokens = j["completion_tokens"].integer.to!int;
        if ("total_tokens" in j)      u.totalTokens      = j["total_tokens"].integer.to!int;
        if ("cost" in j && j["cost"].type == JSONType.float_)
            u.cost = j["cost"].floating;
        return u;
    }

    /// Extracts code and message from JSON error object and throws OpenRouterException.
    /// The "code" field can be integer or string depending on the provider.
    static void throwFromErrorObject(JSONValue err)
    {
        int code = 0;
        string msg = "Unknown error";

        if ("code" in err)
        {
            auto cv = err["code"];
            if (cv.type == JSONType.integer)
                code = cv.integer.to!int;
            else if (cv.type == JSONType.string)
            {
                // String code (e.g. "server_error"): put in message
                msg = cv.str;
                try code = cv.str.to!int; catch (Exception) {}
            }
        }
        if ("message" in err)
            msg = err["message"].str;

        throw new OpenRouterException(code, msg, err.toString());
    }

    /// Parsing of tool calls.
    static ToolCall[] parseToolCalls(JSONValue arr)
    {
        ToolCall[] result;
        foreach (ref tc; arr.array)
        {
            ToolCall t;
            t.id = ("id" in tc) ? tc["id"].str : "";
            if ("function" in tc)
            {
                auto fn = tc["function"];
                t.functionName = ("name" in fn) ? fn["name"].str : "";
                t.functionArguments = ("arguments" in fn) ? fn["arguments"].str : "";
            }
            result ~= t;
        }
        return result;
    }

    /// Parsing of generated images (array of {type, image_url: {url}}).
    static ImageData[] parseImages(JSONValue arr)
    {
        ImageData[] result;
        foreach (ref img; arr.array)
        {
            ImageData d;
            if ("image_url" in img)
            {
                auto iu = img["image_url"];
                if ("url" in iu)
                    d.url = iu["url"].str;
            }
            if (d.url.length > 0)
                result ~= d;
        }
        return result;
    }
}
