# OpenRouter D Library

A comprehensive D language binding for the OpenRouter API, enabling seamless integration of AI models with support for text generation, streaming, image analysis, and image generation.

## Quick Start

### 1. Get Your OpenRouter API Key

It's easy! Head over to [OpenRouter.ai](https://openrouter.ai) and sign up. Your API key will be available in the dashboard. No credit card required to get started with free models.

### 2. Use It in Your Code

You can pass your API key directly to the OpenRouter constructor:

```d
import openrouter;
import std.stdio : writeln;

void main()
{
    string apiKey = "sk-or-v1-your-api-key-here";
    auto or = OpenRouter(apiKey);

    or.addMessage("Tell me a fun fact about space.");
    auto resp = or.complete();

    writeln("Response: ", resp.text);
    writeln("Cost: $", resp.usage.cost.get);
}
```

For production, store your API key securely in an environment variable:

```bash
export OPENROUTER_API_KEY="your-api-key-here"
```

Then read it in your code:

```d
import std.process : environment;

string apiKey = environment.get("OPENROUTER_API_KEY");
```

## Examples Overview

The library includes 11 ready-to-use examples showcasing different features. To run them:

```bash
# First, set your API key
export OPENROUTER_API_KEY="your-api-key-here"

# Run all 11 examples
dub run --config=examples

# Run a specific example (e.g., example 5 - Image Analysis)
dub run --config=examples -- --example 5
```

### What Each Example Demonstrates

1. **Simple Response** - Basic API call to get a single completion
2. **Model Selection and Parameters** - Using specific models and controlling response length/temperature
3. **System Prompt** - Adding system context to guide the model's behavior
4. **Multi-turn Conversation** - Building conversational history for context-aware responses
5. **Image Analysis from URL** - Analyzing images from remote URLs with dynamic redirect handling
6. **Image Analysis from Local File** - Analyzing images from local files (auto base64 encoding)
7. **Image Generation** - Generating images with paid models
8. **Streaming** - Real-time text streaming for faster perceived response
9. **Streaming with Full Chunks** - Access to complete streaming metadata
10. **JSON Mode** - Structured output for programmatic use
11. **Error Handling** - Proper exception handling and API error management

## Features

✨ **Complete API Coverage**
- Text completions
- Streaming support
- Image analysis (local files and remote URLs)
- Image generation
- Multi-turn conversations
- JSON mode for structured output

🎯 **Developer Friendly**
- Fluent API with method chaining
- Automatic base64 encoding for images
- Comprehensive error handling
- Detailed usage and cost tracking

## Installation

Add to your project: `dub add openrouter`

## Supported Models

The library works with all models available on OpenRouter, including:
- **Free Models**: Google Gemma, Mistral, etc.
- **Paid Models**: GPT-4, Claude, Gemini
- **Image Models**: For generation and analysis

Check [OpenRouter Models](https://openrouter.ai/models) for the full list.

## Documentation

Detailed API documentation and examples are available in the `source/examples.d` file. Each example demonstrates a different feature:

- Text generation with various parameters
- Image analysis workflows
- Streaming for real-time responses
- Error handling patterns

## Resources

- [OpenRouter.ai](https://openrouter.ai) - API website
- [D Language](https://dlang.org) - D programming language
- [Dub Package Manager](https://dub.pm) - D's package manager
