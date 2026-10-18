import { z } from 'zod';
import type { Server } from '@modelcontextprotocol/sdk/server/index.js';
import type { GodotConnection } from '../connection/websocket.js';
import { registry } from './registry.js';
import { logger } from '../utils/logger.js';

interface ExtensionTool {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>;
  validate: z.ZodType;
}

// The router owns callables. The server only retains JSON schemas and names,
// which are invalidated on every disconnect before a new editor is discovered.
export class ExtensionTools {
  private tools = new Map<string, ExtensionTool>();
  private generation = 0;

  constructor(
    private readonly connection: GodotConnection,
    private readonly server: Server,
    private readonly readOnly: boolean
  ) {
    connection.on('connected', () => { void this.discover(); });
    connection.on('disconnected', () => this.clear());
  }

  list(): Array<Pick<ExtensionTool, 'name' | 'description' | 'inputSchema'>> {
    return Array.from(this.tools.values(), ({ name, description, inputSchema }) => ({
      name, description, inputSchema,
    }));
  }

  has(name: string): boolean {
    return this.tools.has(name);
  }

  async call(name: string, args: Record<string, unknown>): Promise<unknown> {
    const tool = this.tools.get(name);
    if (!tool || !this.connection.isConnected) throw new Error(`Extension tool unavailable: ${name}`);
    const validated = tool.validate.parse(args) as Record<string, unknown>;
    return this.connection.sendCommand(name, validated);
  }

  private clear(): void {
    this.generation++;
    if (this.tools.size === 0) return;
    this.tools.clear();
    this.notify();
  }

  private notify(): void {
    void this.server.sendToolListChanged().catch((error: unknown) => {
      logger.warning('Unable to notify client of extension tool changes', { error: String(error) });
    });
  }

  private async discover(): Promise<void> {
    const generation = ++this.generation;
    if (this.readOnly) return; // No extension mutator can bypass GODOT_MCP_READ_ONLY.
    try {
      const response = await this.connection.sendCommand<{ tools: Array<{
        name: string; description: string; inputSchema: Record<string, unknown>;
      }> }>('list_extension_tools');
      if (generation !== this.generation || !this.connection.isConnected) return;
      if (!Array.isArray(response?.tools)) throw new Error('Invalid extension discovery response');
      const builtins = new Set(registry.getToolList().map(({ name }) => name));
      const discovered = new Map<string, ExtensionTool>();
      for (const definition of response.tools) {
        if (typeof definition.name !== 'string' || !definition.name.startsWith('godot_') ||
            builtins.has(definition.name) || discovered.has(definition.name) ||
            typeof definition.description !== 'string' ||
            !definition.inputSchema || typeof definition.inputSchema !== 'object' ||
            Array.isArray(definition.inputSchema) || definition.inputSchema.type !== 'object') {
          throw new Error(`Invalid or conflicting extension tool: ${String(definition?.name)}`);
        }
        const validate = z.fromJSONSchema(definition.inputSchema);
        discovered.set(definition.name, { ...definition, validate });
      }
      this.tools = discovered;
      this.notify();
    } catch (error) {
      if (generation === this.generation) {
        this.clear();
        logger.warning('MCP extension discovery failed', { error: String(error) });
      }
    }
  }
}
