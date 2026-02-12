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
    const { messages, collected_data, existing_name } = req.body;

    if (!messages || !Array.isArray(messages)) {
      return res.status(400).json({
        success: false,
        error: 'Missing required field: messages (array)',
      });
    }

    // System prompt for onboarding chat
    const systemMessage = `You are Omi's onboarding assistant. Your job is to warmly welcome new users and collect information through a structured conversation.

REQUIRED INFORMATION (in this order):
1. name - Their name (how they'd like to be addressed)
2. motivation - Why they're using Omi
3. use_case - What kind of work/activities they do
4. job - Their job title or role
5. company - Company they work for (OPTIONAL)

${existing_name ? `USER'S EXISTING NAME: "${existing_name}" (from their account)
- When asking for name, suggest this as the FIRST option
- Also offer "I'll type it" as an alternative
` : ''}
COLLECTED SO FAR:
${JSON.stringify(collected_data || {}, null, 2)}

CONVERSATION FLOW - BE PROACTIVE:
${!collected_data || Object.keys(collected_data).length === 0 ? `
STEP 1: Greet warmly and ask for their NAME
- Use suggest_replies (include "I'll type it" option)
- Make it friendly and casual
` : ''}${!collected_data?.name ? `
CURRENT: Ask for their NAME (how they'd like to be addressed)
- Keep it warm and friendly
- IMPORTANT: If user's name is already in collected_data, suggest it as the first option!
- Use suggest_replies (include "I'll type it" option)
- When they answer, use save_field immediately, then move to next question
` : !collected_data?.motivation ? `
CURRENT: Ask about their MOTIVATION (why they're using Omi)
- Use suggest_replies with options like: "Stay focused", "Boost productivity", "Remember conversations", "Just exploring"
- When they answer, use save_field immediately, then move to next question
` : !collected_data?.use_case ? `
CURRENT: Ask about their USE CASE (what kind of work)
- Acknowledge their motivation briefly
- Use suggest_replies with options like: "Work meetings", "Deep focus time", "Learning & research", "Creative work"
- When they answer, use save_field immediately, then move to next question
` : !collected_data?.job ? `
CURRENT: Ask about their JOB/ROLE
- Acknowledge their use case briefly
- Use suggest_replies with options like: "Software Engineer", "Product Manager", "Designer", "Student", "Researcher"
- When they answer, use save_field immediately, then move to next question
` : !collected_data?.company ? `
CURRENT: Ask about their COMPANY (optional)
- Acknowledge their job briefly
- Use suggest_replies with options like: "Skip this question"
- When they answer OR skip, save if provided, then call complete_onboarding with a warm welcome message
` : `
ALL FIELDS COLLECTED! Call complete_onboarding tool now with a message like "You're all set, [name]! Welcome aboard! 🎉"
`}

CRITICAL RULES:
- ALWAYS ask the next question immediately after saving data
- DON'T just acknowledge - acknowledge AND ask next question in same response
- ALWAYS use suggest_replies when asking questions
- Keep responses brief (2-3 sentences max)
- If user asks about Omi, answer briefly then return to collecting data
- Be warm but efficient - guide them through all 4 fields

ABOUT OMI (for answering questions):
- Omi helps you stay focused and productive by monitoring your screen
- It alerts you when you get distracted and helps you stay on track
- It transcribes conversations and provides context-aware assistance`;

    // Define tools for data collection
    const tools = [
      {
        name: 'save_field',
        description: 'Save a piece of onboarding information when the user provides it. Call this immediately when you learn name, motivation, use_case, job, or company.',
        input_schema: {
          type: 'object',
          properties: {
            field: {
              type: 'string',
              enum: ['name', 'motivation', 'use_case', 'job', 'company'],
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
        name: 'suggest_replies',
        description: 'Suggest 2-4 quick reply options to help guide the user. Use this when asking questions to make it easier for users to respond. User can still type their own response.',
        input_schema: {
          type: 'object',
          properties: {
            suggestions: {
              type: 'array',
              items: { type: 'string' },
              description: 'List of 2-4 suggested responses',
              minItems: 2,
              maxItems: 4,
            },
          },
          required: ['suggestions'],
        },
      },
      {
        name: 'complete_onboarding',
        description: 'Call this when all required fields (name, motivation, use_case, job) are collected. Company is optional. Include a warm welcome message for the user.',
        input_schema: {
          type: 'object',
          properties: {},
        },
      },
    ];

    // Call Anthropic API with conversation history
    let currentMessages = [...messages];
    let attempts = 0;
    const maxAttempts = 3;
    let finalResponse = null;

    while (attempts < maxAttempts) {
      attempts++;

      const message = await anthropic.messages.create({
        model: 'claude-opus-4-6',
        max_tokens: 1024,
        system: systemMessage,
        messages: currentMessages,
        tools: tools,
      });

      // Extract response text and tool calls
      const textBlocks = message.content.filter(block => block.type === 'text');
      const toolUses = message.content.filter(block => block.type === 'tool_use');
      const responseText = textBlocks.map(block => block.text).join('\n');

      // Check what data is still needed
      const needsName = !collected_data?.name;
      const needsMotivation = !collected_data?.motivation;
      const needsUseCase = !collected_data?.use_case;
      const needsJob = !collected_data?.job;
      const needsCompany = !collected_data?.company;
      const allRequiredCollected = collected_data?.name && collected_data?.motivation && collected_data?.use_case && collected_data?.job;

      // Verify Claude is doing the right thing
      const hasSaveField = toolUses.some(t => t.name === 'save_field');
      const hasSuggestReplies = toolUses.some(t => t.name === 'suggest_replies');
      const hasCompleteOnboarding = toolUses.some(t => t.name === 'complete_onboarding');

      // Check if response is appropriate for current state
      let needsCorrection = false;
      let correctionPrompt = '';

      // Critical check: After user responds (messages > 2), we should be saving data
      // If we're missing required fields and not asking a question, we should save_field
      const isUserResponse = currentMessages.length > 2; // More than initial greeting + first AI question
      const isAskingQuestion = hasSuggestReplies || responseText.includes('?');

      if (allRequiredCollected && !hasCompleteOnboarding) {
        // All data collected but didn't call complete_onboarding
        needsCorrection = true;
        correctionPrompt = 'SYSTEM: All required fields are collected (name, motivation, use_case, job). You MUST call complete_onboarding tool now with a welcome message.';
      } else if (isUserResponse && !allRequiredCollected && !hasSaveField && !isAskingQuestion && !hasCompleteOnboarding) {
        // User responded but we didn't save the data and didn't ask a follow-up question
        needsCorrection = true;
        if (needsName) {
          correctionPrompt = 'SYSTEM: User just provided their name. Call save_field with field="name" and the value they provided, then ask for MOTIVATION with suggest_replies.';
        } else if (needsMotivation) {
          correctionPrompt = 'SYSTEM: User just provided their motivation. Call save_field with field="motivation" and the value they provided, then ask for USE_CASE with suggest_replies.';
        } else if (needsUseCase) {
          correctionPrompt = 'SYSTEM: User just provided their use case. Call save_field with field="use_case" and the value they provided, then ask for JOB with suggest_replies.';
        } else if (needsJob) {
          correctionPrompt = 'SYSTEM: User just provided their job. Call save_field with field="job" and the value they provided, then ask for COMPANY with suggest_replies (include "Skip" option).';
        } else if (needsCompany) {
          correctionPrompt = 'SYSTEM: User responded about company. If they provided a company name, call save_field with field="company". Then call complete_onboarding with a welcome message.';
        }
      } else if (!allRequiredCollected && !hasSuggestReplies && currentMessages.length > 1 && responseText.includes('?')) {
        // Asking a question but didn't provide suggestions
        needsCorrection = true;
        correctionPrompt = 'SYSTEM: When asking questions to collect data, you MUST use suggest_replies tool to provide options. Ask the question again with suggestions.';
      }

      if (needsCorrection && attempts < maxAttempts) {
        console.log(`Attempt ${attempts}: Response needs correction. Re-prompting...`);

        // Add assistant's response to conversation
        currentMessages.push({
          role: 'assistant',
          content: message.content,
        });

        // Build tool results for any tool calls (required by Anthropic API)
        const toolResultContent = [];

        for (const toolUse of toolUses) {
          toolResultContent.push({
            type: 'tool_result',
            tool_use_id: toolUse.id,
            content: 'Acknowledged', // Simple acknowledgment
          });
        }

        // Add correction prompt with tool results (text blocks use 'text' field, not 'content')
        toolResultContent.push({
          type: 'text',
          text: correctionPrompt,
        });

        currentMessages.push({
          role: 'user',
          content: toolResultContent,
        });

        // Loop will retry
        continue;
      } else {
        // Response is good or we've hit max attempts
        finalResponse = {
          responseText,
          toolUses,
          stopReason: message.stop_reason,
        };
        break;
      }
    }

    if (!finalResponse) {
      // Shouldn't happen, but fallback
      finalResponse = {
        responseText: 'Let me help you get started with Omi!',
        toolUses: [],
        stopReason: 'end_turn',
      };
    }

    // Log tool calls for debugging
    console.log('Returning response with', finalResponse.toolUses.length, 'tool calls:',
      finalResponse.toolUses.map(t => t.name).join(', '));
    if (finalResponse.toolUses.length > 0) {
      console.log('Tool details:', JSON.stringify(finalResponse.toolUses, null, 2));
    }

    res.json({
      success: true,
      response: finalResponse.responseText,
      tool_calls: finalResponse.toolUses.map(tool => ({
        name: tool.name,
        input: tool.input,
      })),
      stop_reason: finalResponse.stopReason,
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
