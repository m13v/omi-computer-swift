const express = require('express');
const Anthropic = require('@anthropic-ai/sdk');

const app = express();
app.use(express.json());

const port = process.env.AGENT_SERVICE_PORT || 8081;
const apiKey = process.env.ANTHROPIC_API_KEY;

if (!apiKey) {
  console.error('ANTHROPIC_API_KEY environment variable is required');
  process.exit(1);
}

const anthropic = new Anthropic({
  apiKey: apiKey,
});

// Health check endpoint
app.get('/health', (req, res) => {
  res.json({
    status: 'ok',
    timestamp: new Date().toISOString(),
  });
});

// Agent execution endpoint
app.post('/agent/run', async (req, res) => {
  try {
    const { prompt, context } = req.body;

    if (!prompt) {
      return res.status(400).json({
        success: false,
        error: 'Missing required field: prompt',
      });
    }

    // Build system message with context if provided
    let systemMessage = 'You are a helpful AI assistant.';
    if (context && Object.keys(context).length > 0) {
      systemMessage += '\n\nContext:\n';
      for (const [key, value] of Object.entries(context)) {
        systemMessage += `${key}: ${value}\n`;
      }
    }

    // Call Anthropic API
    const message = await anthropic.messages.create({
      model: 'claude-opus-4-6',
      max_tokens: 1024,
      system: systemMessage,
      messages: [
        {
          role: 'user',
          content: prompt,
        },
      ],
    });

    // Extract text from response
    const responseText = message.content
      .filter(block => block.type === 'text')
      .map(block => block.text)
      .join('\n');

    res.json({
      success: true,
      response: responseText,
    });
  } catch (error) {
    console.error('Agent execution error:', error);
    res.status(500).json({
      success: false,
      error: error.message || 'Internal server error',
    });
  }
});

app.listen(port, () => {
  console.log(`Agent service listening on port ${port}`);
});

// Graceful shutdown
process.on('SIGTERM', () => {
  console.log('SIGTERM signal received: closing HTTP server');
  process.exit(0);
});

process.on('SIGINT', () => {
  console.log('SIGINT signal received: closing HTTP server');
  process.exit(0);
});
