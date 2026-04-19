// src/modules/confluence-rag/api-token.guard.ts
import {
  CanActivate,
  ExecutionContext,
  Injectable,
  Logger,
  UnauthorizedException,
} from '@nestjs/common';

/**
 * Guard simples pra proteger endpoints que só devem ser chamados pela
 * CustomApps/automation. Valida header:
 *
 *   Authorization: Bearer <API_TOKEN>
 *
 * O token vem do env var API_TOKEN.
 *
 * Se API_TOKEN não estiver setado no .env, o guard DEIXA PASSAR (útil em dev).
 * Em produção SEMPRE configure API_TOKEN.
 */
@Injectable()
export class ApiTokenGuard implements CanActivate {
  private readonly logger = new Logger(ApiTokenGuard.name);

  canActivate(context: ExecutionContext): boolean {
    const expected = process.env.API_TOKEN;

    if (!expected) {
      this.logger.warn(
        '⚠️  API_TOKEN não configurado no .env — endpoint está ABERTO (ok em dev, PERIGOSO em prod)',
      );
      return true;
    }

    const req = context.switchToHttp().getRequest();
    const auth = req.headers['authorization'] ?? '';
    const token = auth.startsWith('Bearer ') ? auth.slice(7) : '';

    if (token !== expected) {
      throw new UnauthorizedException(
        'Token inválido ou ausente. Envie header "Authorization: Bearer <token>".',
      );
    }

    return true;
  }
}
