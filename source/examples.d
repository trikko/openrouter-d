/// Usage examples of the OpenRouter library for D.
/// Each function demonstrates a different use case.
/// Usage: dub run --config=examples -- [--example N]
module examples;

import openrouter;
import std;

// -- ANSI codes for coloring terminal output ---------------------------------
struct C
{
    static immutable string bold  = "\x1b[1m";
    static immutable string dim   = "\x1b[2m";
    static immutable string red   = "\x1b[31m";
    static immutable string green = "\x1b[32m";
    static immutable string yellow= "\x1b[33m";
    static immutable string cyan  = "\x1b[36m";
    static immutable string reset = "\x1b[0m";
}

/// Global API key initialized in main()
string apiKey;

/// Prints a field name/value pair with colors.
void field(string label, string value)
{
    writeln("  ", C.bold, label, C.reset, " ", value);
}

/// Prints the cost of the request from usage.
void showCost(Usage u)
{
    if (!u.cost.isNull)
        field("Cost:", format!"$%.6f"(u.cost.get));
    else
        field("Cost:", "$0.00 (free)");
}

/// Gets the final URL after HTTP redirects by reading the Location header.
string getRedirectUrl(string url)
{
    auto http = HTTP();
    http.url = url;

    string locationHeader;
    http.onReceiveHeader = (in char[] key, in char[] value) {
        import std.string : toLower;
        if (toLower(key) == "location")
            locationHeader = value.idup;
    };

    // Perform request to get the Location header
    try
    {
        http.onReceive = (ubyte[] data) {
            return data.length;  // Discard body
        };
        http.perform();
    }
    catch (Exception) { }

    // If we got a redirect, return the Location header; otherwise return original URL
    return locationHeader.length > 0 ? locationHeader : url;
}

/// Runs an example, catching errors so other examples can continue.
void runExample(int num, string title, void function() fn)
{
    writeln();
    writeln(C.bold, C.cyan, format!"  [%d] %s"(num, title), C.reset);
    writeln();
    try
    {
        fn();
    }
    catch (OpenRouterException e)
    {
        writeln("  ", C.red, "API ERROR: ", e.msg, C.reset);
        if (e.code != 0)
            writeln("  ", C.dim, "Code: ", e.code, C.reset);
        if (e.details.length > 0)
            writeln("  ", C.dim, "Details: ", e.details, C.reset);
    }
    catch (Exception e)
    {
        writeln("  ", C.red, "ERROR: ", e.msg, C.reset);
    }
    writeln();
}

// ---------------------------------------------------------------------------
//  1. Simple Response
// ---------------------------------------------------------------------------
void exampleSimple()
{
    auto or = OpenRouter(apiKey);

    or.addMessage("Tell me an interesting fact about the Moon in one sentence.");
    auto resp = or.complete();

    field("Model:", resp.model);
    field("Response:", resp.text);
    field("Finish reason:", resp.finishReason
        ~ (resp.finishReason == "stop" ? " (natural completion)" : ""));
    field("Prompt tokens:", resp.usage.promptTokens.to!string);
    field("Response tokens:", resp.usage.completionTokens.to!string);
    field("Total tokens:", resp.usage.totalTokens.to!string);
    showCost(resp.usage);
}

// ---------------------------------------------------------------------------
//  2. Model Selection and Parameters
// ---------------------------------------------------------------------------
void exampleWithModel()
{
    auto or = OpenRouter(apiKey, "google/gemma-3-4b-it:free");

    or.setTemperature(0.3)
      .setMaxTokens(100)
      .addMessage("Explain what a quasar is in 2 sentences.");

    auto resp = or.complete();
    field("Model:", resp.model);
    field("Response:", resp.text);
    field("Tokens used:", resp.usage.totalTokens.to!string ~ " (max_tokens was 100)");
    showCost(resp.usage);
}

// ---------------------------------------------------------------------------
//  3. System Prompt
// ---------------------------------------------------------------------------
void exampleSystemPrompt()
{
    auto or = OpenRouter(apiKey);

    or.setSystemPrompt("You are a pirate. Always respond in a pirate theme.")
      .addMessage("What's the weather like today?");

    auto resp = or.complete();
    field("Model:", resp.model);
    field("System:", "\"You are a pirate...\"");
    field("User:", "\"What's the weather like today?\"");
    field("Response:", resp.text);
    showCost(resp.usage);
}

// ---------------------------------------------------------------------------
//  4. Multi-turn Conversation
// ---------------------------------------------------------------------------
void exampleConversation()
{
    auto or = OpenRouter(apiKey);

    or.addMessage("My favorite color is blue. Remember that.");
    auto r1 = or.complete();
    field("Model:", r1.model);
    field("User:", "\"My favorite color is blue. Remember that.\"");
    field("Assistant:", r1.text);

    or.addResponse(r1);

    or.addMessage("What is my favorite color?");
    auto r2 = or.complete();
    field("User:", "\"What is my favorite color?\"");
    field("Assistant:", r2.text);
    field("Messages in history:", or.messages.length.to!string);
    showCost(r2.usage);
}

// ---------------------------------------------------------------------------
//  5. Image Analysis from Remote URL with Dynamic Redirect Handling
//  Note: https://picsum.photos redirects to fastly.picsum.photos with dynamic HMAC
// ---------------------------------------------------------------------------
void exampleImageUrl()
{
    auto picsum_url = "https://picsum.photos/720/1280";

    // Get the actual redirect URL with dynamic HMAC
    auto redirect_url = getRedirectUrl(picsum_url);
    field("Original URL:", picsum_url);
    field("Redirect URL:", redirect_url);

    auto or = OpenRouter(apiKey);

    or.addMessage([
        ContentPart.text(
            "Analyze this photograph in detailed technical terms. Imagine you need to explain it " ~
            "to an artist who will paint an exact reproduction without seeing the original. " ~
            "Describe:\n" ~
            "1. Overall composition and layout\n" ~
            "2. Main subjects and their spatial relationships\n" ~
            "3. Colors, tones, and lighting conditions\n" ~
            "4. Textures and materials visible\n" ~
            "5. Atmosphere and mood conveyed\n" ~
            "6. Technical details (depth of field, perspective, focal points)\n" ~
            "Be as precise as possible so the reproduction would be indistinguishable from the original.\n" ~
            "Use only three sentences at most, without any formatting."
        ),
        ContentPart.imageUrl(redirect_url)  // Use the redirect URL with HMAC
    ]);

    auto resp = or.complete();
    field("Model:", resp.model);
    field("Response:", resp.text);
    showCost(resp.usage);
}

// ---------------------------------------------------------------------------
//  6. Image Analysis from Local File
//  imageFile() reads the file and automatically converts it to base64 data-URI.
// ---------------------------------------------------------------------------
void exampleImageLocal()
{
    auto or = OpenRouter(apiKey, "google/gemma-3-27b-it:free");

    or.addMessage([
        ContentPart.text("Report the main subject of the photo in at most three words."),
        ContentPart.imageFile("example.jpg")
    ]);

    auto resp = or.complete();
    field("Model:", resp.model);
    field("Image:", "example.jpg (local file, sent as base64)");
    field("Response:", resp.text);
    showCost(resp.usage);
}

// ---------------------------------------------------------------------------
//  7. Image Generation — Saving to Disk
//  Note: Requires a paid model (e.g. gemini-2.5-flash-image).
//  The image is returned as base64 in the images field of the response.
// ---------------------------------------------------------------------------
void exampleImageGeneration()
{
    if (true) {
        field("Skipped:", "paid only - enable generation removing this if condition");
        return;
    }

    auto or = OpenRouter(apiKey, "google/gemini-2.5-flash-image");

    // modalities ["text", "image"] enables image generation
    or.setModalities(["text", "image"])
      .addMessage("Create a realistic photo of a cat curled up sleeping in a lunar crater. It must not look fake or photoshopped. Shadows and light must be coherent and the photo high quality.");

    auto resp = or.complete();
    field("Model:", resp.model);

    if (resp.text.length > 0)
        field("Text:", resp.text);

    if (resp.images.length > 0)
    {
        field("Images received:", resp.images.length.to!string);
        // Use the new save() method to save the image
        try
        {
            auto savedPath = resp.images[0].save(".");
            field("Saved to:", C.green ~ "file://" ~ absolutePath(savedPath) ~ C.reset);
            import std.file : getSize;
            field("Size:", format!"%d bytes"(getSize(savedPath)));
        }
        catch (Exception e)
        {
            field("Error saving:", e.msg);
        }
    }
    else
    {
        writeln("  ", C.yellow, "No images in response.", C.reset);
    }
    showCost(resp.usage);
}

// ---------------------------------------------------------------------------
//  8. Streaming
// ---------------------------------------------------------------------------
void exampleStreaming()
{
    auto or = OpenRouter(apiKey);

    or.addMessage("Write a short poem about D programming (4 lines).");

    field("Model:", or.model);
    write("  ");
    auto result = or.stream((string text) {
        writef("%s", text);
        stdout.flush();
    });

    writeln();
    field("Tokens used:", result.usage.totalTokens.to!string);
    showCost(result.usage);
}

// ---------------------------------------------------------------------------
//  9. Streaming with Full Chunks
// ---------------------------------------------------------------------------
void exampleStreamingFull()
{
    auto or = OpenRouter(apiKey);

    or.addMessage("List 3 programming languages with one line for each.");

    field("Model:", or.model);
    write("  ");
    auto result = or.streamFull((StreamChunk chunk) {
        if (!chunk.content.isNull)
            writef("%s", chunk.content.get);
        if (!chunk.finishReason.isNull)
            writef(C.dim ~ "  [finish_reason: %s]" ~ C.reset, chunk.finishReason.get);
    });

    writeln();
    field("Tokens used:", result.usage.totalTokens.to!string);
    showCost(result.usage);
}

// ---------------------------------------------------------------------------
// 10. JSON Mode
// ---------------------------------------------------------------------------
void exampleJsonMode()
{
    auto or = OpenRouter(apiKey);

    or.setJsonMode()
      .addMessage(`Return a JSON with "name", "age", and "hobby" fields for an invented person.`);

    auto resp = or.complete();
    field("Model:", resp.model);
    field("JSON received:", "");
    writeln("  ", C.green, resp.text, C.reset);
    showCost(resp.usage);
}

// ---------------------------------------------------------------------------
// 11. Error Handling
// ---------------------------------------------------------------------------
void exampleErrorHandling()
{
    auto or = OpenRouter("invalid-key-12345");
    or.addMessage("Test");

    try
    {
        or.complete();
        writeln("  No error (unexpected!)");
    }
    catch (OpenRouterException e)
    {
        writeln("  ", C.green, "Exception caught correctly:", C.reset);
        field("Type:", "OpenRouterException");
        field("Code:", e.code.to!string);
        field("Message:", e.msg);
    }
}

// ---------------------------------------------------------------------------
//  Examples Table
// ---------------------------------------------------------------------------
struct Example
{
    int num;
    string title;
    void function() fn;
}

immutable examples = [
    Example( 1, "Simple Response",                  &exampleSimple),
    Example( 2, "Model Selection and Parameters",    &exampleWithModel),
    Example( 3, "System Prompt",                     &exampleSystemPrompt),
    Example( 4, "Multi-turn Conversation",           &exampleConversation),
    Example( 5, "Image Analysis (URL)",              &exampleImageUrl),
    Example( 6, "Image Analysis (Local File)",       &exampleImageLocal),
    Example( 7, "Image Generation",                  &exampleImageGeneration),
    Example( 8, "Streaming",                         &exampleStreaming),
    Example( 9, "Streaming with Full Chunks",        &exampleStreamingFull),
    Example(10, "JSON Mode",                         &exampleJsonMode),
    Example(11, "Error Handling",                    &exampleErrorHandling),
];

// ---------------------------------------------------------------------------
//  Main
// ---------------------------------------------------------------------------
void main(string[] args)
{
    int only = 0;
    apiKey = environment.get("OPENROUTER_API_KEY", "");

    if (apiKey.length == 0)
    {
        stderr.writeln(C.red, "Error: set the OPENROUTER_API_KEY environment variable", C.reset);
        assert(false);
    }

    try
    {
        auto opts = getopt(args, "example|e", "Run only example N (1-11)", &only);
        if (opts.helpWanted)
        {
            writeln("Usage: examples [--example N]");
            writeln("  --example N, -e N   Run only example number N (1-11)");
            writeln();
            writeln("Available examples:");
            foreach (ref ex; examples)
                writeln(format!"  %2d  %s"(ex.num, ex.title));
            return;
        }
    }
    catch (GetOptException e)
    {
        stderr.writeln(C.red, "Invalid argument: ", e.msg, C.reset);
        return;
    }

    writeln(C.bold, "OpenRouter D Library — Examples", C.reset);
    writeln(C.dim, "Default model: openrouter/free", C.reset);

    if (only > 0)
    {
        bool found = false;
        foreach (ref ex; examples)
        {
            if (ex.num == only)
            {
                runExample(ex.num, ex.title, ex.fn);
                found = true;
                break;
            }
        }
        if (!found)
        {
            stderr.writeln(C.red, format!"Example %d not found (valid: 1-11)"(only), C.reset);
        }
    }
    else
    {
        foreach (ref ex; examples)
            runExample(ex.num, ex.title, ex.fn);
    }

    writeln(C.bold, "Done.", C.reset);
}
