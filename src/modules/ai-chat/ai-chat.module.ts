import { Module } from "@nestjs/common";
import { AiChatController } from "./ai-chat.controller";
import { AiChatService } from "./ai-chat.service";
import { ConversationsStoreService } from "./conversations-store.service";

@Module({
  controllers: [AiChatController],
  providers: [AiChatService, ConversationsStoreService],
})
export class AiChatModule {}
