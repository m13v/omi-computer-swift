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

// Onboarding chat endpoint with conversation history and tool use
app.post('/agent/chat', async (req, res) => {
  try {
    const { messages, collected_data } = req.body;

    if (!messages || !Array.isArray(messages)) {
      return res.status(400).json({
        success: false,
        error: 'Missing required field: messages (array)',
      });
    }

    // System prompt for onboarding chat
    const systemMessage = `You are Omi's onboarding assistant. Your job is to warmly welcome new users and collect information about them through natural conversation.

REQUIRED INFORMATION TO COLLECT:
1. motivation - Why they're using Omi (e.g., "stay focused", "boost productivity")
2. use_case - What kind of work they do (e.g., "work meetings", "deep focus time")
3. job - Their job title or role (e.g., "Software Engineer", "Student")
4. company - Company they work for (OPTIONAL - they can skip this)

COLLECTED SO FAR:
${JSON.stringify(collected_data || {}, null, 2)}

YOUR APPROACH:
- Be warm, conversational, and helpful
- Answer any questions they have about Omi
- Naturally guide the conversation to collect the missing information
- Don't ask for information that's already collected
- When they provide information, use the save_field tool immediately
- Once ALL required fields are collected, use complete_onboarding tool
- Keep responses brief (2-3 sentences max)

ABOUT OMI:
- Omi is an AI assistant that helps you stay focused and productive
- It monitors your screen and alerts you when you get distracted
- It transcribes conversations and provides context-aware assistance`;

    // Define tools for data collection
    const tools = [
      {
        name: 'save_field',
        description: 'Save a piece of onboarding information when the user provides it. Call this immediately when you learn motivation, use_case, job, or company.',
        input_schema: {
          type: 'object',
          properties: {
            field: {
              type: 'string',
              enum: ['motivation', 'use_case', 'job', 'company'],
              description: 'Which field to save',
            },
            value: {
              type: 'string',
              description: 'The value to save',
            },
          },
          required: ['field', 'value'],
        },
      },
      {
        name: 'complete_onboarding',
        description: 'Call this when all required fields (motivation, use_case, job) are collected. Company is optional.',
        input_schema: {
          type: 'object',
          properties: {},
        },
      },
    ];

    // Call Anthropic API with conversation history
    const message = await anthropic.messages.create({
      model: 'claude-opus-4-6',
      max_tokens: 1024,
      system: systemMessage,
      messages: messages,
      tools: tools,
    });

    // Extract response text and tool calls
    const textBlocks = message.content.filter(block => block.type === 'text');
    const toolUses = message.content.filter(block => block.type === 'tool_use');

    const responseText = textBlocks.map(block => block.text).join('\n');

    res.json({
      success: true,
      response: responseText,
      tool_calls: toolUses.map(tool => ({
        name: tool.name,
        input: tool.input,
      })),
      stop_reason: message.stop_reason,
    });
  } catch (error) {
    console.error('Agent chat error:', error);
    res.status(500).json({
      success: false,
      error: error.message || 'Internal server error',
    });
  }
});

// Legacy endpoint for backwards compatibility
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
