import 'package:shelf/shelf.dart' as shelf;
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

abstract class ProxyRule {
  ProxyRule({required this.target});

  final String target;
  String replace(String path);
  bool matches(String path);

  String getReplacedPath(String path) {
    return normalizePath(replace(path));
  }

  static ProxyRule? fromYaml(YamlMap yaml, {Logger? logger}) {
    final String? target = yaml['target'] as String?;
    final String? source = yaml['source'] as String?;
    final String? regex = yaml['regex'] as String?;
    final String? replace = yaml['replace'] as String?;
    final Logger effectiveLogger = logger ?? globals.logger;

    RegExp? proxyPattern;

    if (target == null) {
      effectiveLogger.printError("Invalid 'target'. 'target' cannot be null");
      return null;
    }
    //source
    if (source != null && source.isNotEmpty) {
      return SourceProxyRule(
        source: normalizePath(source),
        target: target,
        replacement: replace?.trim(),
      );
    }
    //regex
    else if (regex != null && regex.isNotEmpty) {
      try {
        proxyPattern = RegExp(regex.trim());
      } on FormatException catch (e) {
        proxyPattern = RegExp(RegExp.escape(regex));
        effectiveLogger.printWarning(
          "Invalid regex pattern in replace 'regex': '$regex'. Treating $regex as string. Error: $e",
        );
      }
      return RegexProxyRule(pattern: proxyPattern, target: target, replacement: replace?.trim());
    } else {
      effectiveLogger.printError("'source' or 'regex' field must be provided");
      return null;
    }

    return RegexProxyConfig(
      pattern: proxyPattern,
      target: yaml['target'] as String,
      rewrite: rewriteFn,
    );
  }
}

class RegexProxyRule extends ProxyRule {
  RegexProxyRule({required this.pattern, required super.target, this.replacement});

  final RegExp pattern;
  final String? replacement;

  @override
  bool matches(String path) {
    return pattern.hasMatch(path);
  }

  @override
  String replace(String path) {
    if (replacement == null) {
      return path;
    }
    return path.replaceAllMapped(pattern, (Match match) {
      String result = replacement!;

      for (int i = 0; i <= match.groupCount; i++) {
        result = result.replaceAll('\$$i', match.group(i) ?? '');
      }
      return result;
    });
  }

  @override
  String toString() {
    return '{pattern: ${pattern.pattern}, target: $target, replacement: ${replacement ?? 'null'}}}';
  }
}

class SourceProxyRule extends ProxyRule {
  SourceProxyRule({required this.source, required super.target, this.replacement});
  final String source;
  final String? replacement;

  @override
  bool matches(String path) {
    return path.startsWith(source);
  }

  @override
  String replace(String path) {
    if (replacement == null) {
      return path;
    }
    return path.replaceFirst(source, replacement!);
  }

  @override
  String toString() {
    return '{source: $source, target: $target, replacement: ${replacement ?? 'null'}}}';
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

shelf.Middleware proxyMiddleware(List<ProxyRule> effectiveProxy) {
  return (shelf.Handler innerHandler) {
    return (shelf.Request request) async {
      final String requestPath = normalizePath(request.url.path);
      for (final ProxyRule rule in effectiveProxy) {
        if (rule.matches(requestPath)) {
          final Uri targetBaseUri = Uri.parse(rule.target);
          final String rewrittenRequest = rule.getReplacedPath(requestPath);
          final Uri finalTargetUrl = targetBaseUri.resolve(rewrittenRequest);
          try {
            final shelf.Request proxyBackendRequest = proxyRequest(request, finalTargetUrl);
            final shelf.Response proxyResponse = await proxyHandler(targetBaseUri)(
              proxyBackendRequest,
            );

            if (proxyResponse.statusCode == 404) {
              return innerHandler(request);
            }
            return proxyResponse;
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
