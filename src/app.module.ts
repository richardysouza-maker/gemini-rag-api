import { Module } from '@nestjs/common';
import { ConfigModule } from '@nestjs/config';
import { ServeStaticModule } from '@nestjs/serve-static';
import { join } from 'path';
import { AppController } from './app.controller';
import { AppService } from './app.service';
import { ConfluenceRagModule } from './modules/confluence-rag/confluence-rag.module';

@Module({
  imports: [
    ConfigModule.forRoot({ isGlobal: true }),
    ServeStaticModule.forRoot({
      rootPath: join(__dirname, '..', 'public'),
      exclude: ['/rag/(.*)'], // tudo em /rag/* continua sendo API
    }),
    ConfluenceRagModule,
  ],
  controllers: [AppController],
  providers: [AppService],
})
export class AppModule {}
