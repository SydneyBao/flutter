import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_proxy/shelf_proxy.dart';
import 'package:yaml/yaml.dart';

import '/src/base/logger.dart';
import '../globals.dart' as globals;

String normalizePath(String path) {
  String normalized = path.replaceAll(RegExp(r'/+'), '/');

  if (!normalized.startsWith('/')) {
    normalized = '/$normalized';
  }

  return normalized;
}

abstract class ProxyConfig {
  ProxyConfig({required this.target, this.rewrite});

  factory ProxyConfig.fromYaml(String key, YamlMap yaml, {Logger? logger}) {
    String Function(String)? rewriteFn;

    final dynamic rewriteYamlValue = yaml['rewrite'];

    final Logger effectiveLogger = logger ?? globals.logger;

    if (rewriteYamlValue is bool && rewriteYamlValue) {
      rewriteFn = (String path) => path.replaceFirst(key, '');
    } else if (rewriteYamlValue is String && rewriteYamlValue.isNotEmpty) {
      final List<String> parts = rewriteYamlValue.split('->');

      if (parts.length == 2) {
        final RegExp pattern = RegExp(parts[0].trim());

        final String replacementTemplate = parts[1].trim();

        rewriteFn = (String path) {
          return path.replaceAllMapped(pattern, (Match match) {
            String result = replacementTemplate;

            for (int i = 0; i <= match.groupCount; i++) {
              result = result.replaceAll('\$$i', match.group(i) ?? '');
            }

            return result;
          });
        };
      } else {
        effectiveLogger.printWarning(
          "Invalid rewrite rule format. Expected 'regex -> replacement'. Ignoring rewrite.",
        );
      }
    }

    if (key.startsWith('^')) {
      try {
        return RegexProxyConfig(
          pattern: RegExp(key),

          target: yaml['target'] as String,

          rewrite: rewriteFn,
        );
      } on FormatException catch (e) {
        effectiveLogger.printWarning('Invalid regex pattern "$key". Treating as string prefix: $e');

        return StringPrefixProxyConfig(
          prefix: key,

          target: yaml['target'] as String,

          rewrite: rewriteFn,
        );
      }
    } else {
      return StringPrefixProxyConfig(
        prefix: key,

        target: yaml['target'] as String,

        rewrite: rewriteFn,
      );
    }
  }

  final String target;

  final String Function(String)? rewrite;

  bool matches(String path);

  String getRewrittenPath(String path) {
    return normalizePath(rewrite?.call(path) ?? path);
  }
}

class StringPrefixProxyConfig extends ProxyConfig {
  StringPrefixProxyConfig({required this.prefix, required super.target, super.rewrite});

  final String prefix;

  @override
  bool matches(String path) {
    return path.startsWith(prefix);
  }

  @override
  String toString() {
    return '{prefix: $prefix, target: $target, rewrite: ${rewrite != null ? 'yes' : 'no'}}';
  }
}

class RegexProxyConfig extends ProxyConfig {
  RegexProxyConfig({required this.pattern, required super.target, super.rewrite});

  final RegExp pattern;

  @override
  bool matches(String path) {
    String patternSource = pattern.pattern;
    if (patternSource.isNotEmpty && patternSource.endsWith('/')) {
      patternSource = patternSource.substring(0, patternSource.length - 1);
    }
    final RegExp modifiedPattern = RegExp(patternSource);
    return modifiedPattern.hasMatch(path);
  }

  @override
  String toString() {
    return '{pattern: ${pattern.pattern}, target: $target, rewrite: ${rewrite != null ? 'yes' : 'no'}}';
  }
}

shelf.Request proxyRequest(shelf.Request originalRequest, Uri finalTargetUrl) {
  return shelf.Request(
    originalRequest.method,

    finalTargetUrl,

    headers: originalRequest.headers,

    body: originalRequest.read(),

    context: originalRequest.context,
  );
}

shelf.Middleware proxyMiddleware(List<ProxyConfig> effectiveProxy) {
  return (shelf.Handler innerHandler) {
    return (shelf.Request request) async {
      final String requestPath = normalizePath(request.url.path);

      for (final ProxyConfig config in effectiveProxy) {
        if (config.matches(requestPath)) {
          final Uri targetBaseUri = Uri.parse(config.target);
          final String rewrittenRequest = config.getRewrittenPath(requestPath);
          final Uri finalTargetUrl = targetBaseUri.resolve(rewrittenRequest);
          try {
            final shelf.Request proxyBackendRequest = proxyRequest(request, finalTargetUrl);

            return await proxyHandler(targetBaseUri)(proxyBackendRequest);
          } on Exception catch (e) {
            globals.logger.printError(
              'Proxy error for $finalTargetUrl: $e. Allowing fall-through.',
            );

            return innerHandler(request);
          }
        }
      }

      return innerHandler(request);
    };
  };
}
