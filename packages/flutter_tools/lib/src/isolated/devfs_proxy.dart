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

abstract class ProxyConfig {
  ProxyConfig({required this.target, this.rewrite});

  factory ProxyConfig.fromYaml(String key, YamlMap yaml, {Logger? logger}) {
    String Function(String)? rewriteFn;

    final dynamic rewriteYamlValue = yaml['rewrite'];

    final Logger effectiveLogger = logger ?? globals.logger;

    if (rewriteYamlValue is bool && rewriteYamlValue) {
      rewriteFn = (String path) => path.replaceFirst(key, '');
    } else if (rewriteYamlValue is YamlMap) {
      final dynamic source = rewriteYamlValue['source'];
      final dynamic destination = rewriteYamlValue['destination'];

      if (source is String && source.isNotEmpty && destination is String) {
        try {
          final RegExp pattern = RegExp(source.trim());
          final String replacementTemplate = destination.trim();

          rewriteFn = (String path) {
            return path.replaceAllMapped(pattern, (Match match) {
              String result = replacementTemplate;

              for (int i = 0; i <= match.groupCount; i++) {
                result = result.replaceAll('\$$i', match.group(i) ?? '');
              }
              return result;
            });
          };
        } on FormatException catch (e) {
          effectiveLogger.printWarning(
            "Invalid regex pattern in rewrite 'source': '$source'. Ignoring rewrite. Error: $e",
          );
        }
      } else {
        effectiveLogger.printWarning(
          "Invalid rewrite rule format. Expected 'source' and 'destination' fields in rewrite map. Ignoring rewrite.",
        );
      }
    } else if (rewriteYamlValue != null) {
      effectiveLogger.printWarning(
        "Invalid rewrite rule format. Expected 'bool' or 'Map' for rewrite. Ignoring rewrite.",
      );
    }
    RegExp proxyPattern;
    if (key.startsWith('^')) {
      try {
        if (key.isNotEmpty && key.endsWith('/')) {
          key = key.substring(0, key.length - 1);
        }
        proxyPattern = RegExp(key);
      } on FormatException catch (e) {
        effectiveLogger.printWarning('Invalid regex pattern "$key". Treating as string prefix: $e');
        proxyPattern = RegExp('^${RegExp.escape(key)}');
      }
    } else {
      proxyPattern = RegExp('^${RegExp.escape(key)}');
    }

    return RegexProxyConfig(
      pattern: proxyPattern,
      target: yaml['target'] as String,
      rewrite: rewriteFn,
    );
  }

  final String target;
  final String Function(String)? rewrite;

  bool matches(String path);

  String getRewrittenPath(String path) {
    return normalizePath(rewrite?.call(path) ?? path);
  }
}

class RegexProxyConfig extends ProxyConfig {
  RegexProxyConfig({required this.pattern, required super.target, super.rewrite});

  final RegExp pattern;

  @override
  bool matches(String path) {
    return pattern.hasMatch(path);
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
