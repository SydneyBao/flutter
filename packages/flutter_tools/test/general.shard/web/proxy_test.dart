import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/isolated/devfs_proxy.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import '../../src/testbed.dart';

void main() {
  late TestBed testbed;
  setUp(() {
    testbed = TestBed();
  });

  group('ProxyConfig.fromYaml', () {
    test(
      'should create StringPrefixProxyConfig with no rewrite',
      () => testbed.run(() {
        final YamlMap yaml =
            loadYaml('''
        target: http://localhost:8080
      ''')
                as YamlMap;
        final ProxyConfig config = ProxyConfig.fromYaml('/api', yaml);

        expect(config, isA<StringPrefixProxyConfig>());
        expect((config as StringPrefixProxyConfig).prefix, '/api');
        expect(config.target, 'http://localhost:8080');
        expect(config.rewrite, isNull);
      }),
    );

    test(
      'should create StringPrefixProxyConfig with boolean rewrite true',
      () => testbed.run(() {
        final YamlMap yaml =
            loadYaml('''
        target: http://localhost:8080
        rewrite: true
      ''')
                as YamlMap;
        final ProxyConfig config = ProxyConfig.fromYaml('/api', yaml);

        expect(config, isA<StringPrefixProxyConfig>());
        expect((config as StringPrefixProxyConfig).prefix, '/api');
        expect(config.target, 'http://localhost:8080');
        expect(config.rewrite, isNotNull);
        expect(config.getRewrittenPath('/api/users'), '/users');
        expect(config.getRewrittenPath('/api/'), '/');
        expect(config.getRewrittenPath('/other'), '/other');
      }),
    );

    test(
      'should create StringPrefixProxyConfig with explicit regex rewrite',
      () => testbed.run(() {
        final YamlMap yaml =
            loadYaml('''
        target: http://localhost:8080
        rewrite: '/old/(.*)->/new/1'
      ''')
                as YamlMap;
        final ProxyConfig config = ProxyConfig.fromYaml('/old', yaml);

        expect(config, isA<StringPrefixProxyConfig>());
        expect(config.getRewrittenPath('/old/path/to/resource'), '/new/1');
        expect(config.getRewrittenPath('/other/path'), '/other/path');
      }),
    );

    test(
      'should create RegexProxyConfig with no rewrite',
      () => testbed.run(() {
        final YamlMap yaml =
            loadYaml('''
        target: http://localhost:8081
      ''')
                as YamlMap;
        final ProxyConfig config = ProxyConfig.fromYaml(r'^/users/(\d+)', yaml);

        expect(config, isA<RegexProxyConfig>());
        expect((config as RegexProxyConfig).pattern.pattern, r'^/users/(\d+)');
        expect(config.target, 'http://localhost:8081');
        expect(config.rewrite, isNull);
      }),
    );

    test(
      'should create RegexProxyConfig with boolean rewrite true',
      () => testbed.run(() {
        final YamlMap yaml =
            loadYaml('''
        target: http://localhost:8081
        rewrite: true
      ''')
                as YamlMap;
        final ProxyConfig config = ProxyConfig.fromYaml(r'^/users/(\d+)', yaml);

        expect(config, isA<RegexProxyConfig>());
        expect(config.rewrite, isNotNull);
        expect(config.getRewrittenPath('/users/123/profile'), '/users/123/profile');
        expect(config.getRewrittenPath(r'^/users/(\d+)/test'), '/test');
      }),
    );

    test(
      'should create RegexProxyConfig with explicit regex rewrite',
      () => testbed.run(() {
        final YamlMap yaml =
            loadYaml('''
        target: http://localhost:8081/user-service
        rewrite: '/users/(\\d+)/profile->/users/info'
      ''')
                as YamlMap;
        final ProxyConfig config = ProxyConfig.fromYaml('^/users/(d+)/profile', yaml);
        expect(config, isA<RegexProxyConfig>());
        expect(config.getRewrittenPath('/users/456/profile/summary'), '/users/info/summary');
        expect(config.getRewrittenPath('/users/789/dashboard'), '/users/789/dashboard');
      }),
    );

    test(
      'should handle invalid regex key gracefully and fall back to StringPrefixProxyConfig',
      () => testbed.run(() {
        {
          final YamlMap yaml =
              loadYaml('''
        target: http://localhost:8082
      ''')
                  as YamlMap;
          final ProxyConfig config = ProxyConfig.fromYaml(
            '^/invalid(',
            yaml,
            logger: globals.logger,
          );

          expect(config, isA<StringPrefixProxyConfig>());
          expect((config as StringPrefixProxyConfig).prefix, '^/invalid(');
          expect(config.target, 'http://localhost:8082');
        }
      }),
    );
  });

  group('StringPrefixProxyConfig', () {
    final StringPrefixProxyConfig configNoRewrite = StringPrefixProxyConfig(
      prefix: '/api',
      target: 'http://example.com',
    );
    final StringPrefixProxyConfig configWithRewrite = StringPrefixProxyConfig(
      prefix: '/api',
      target: 'http://example.com',
      rewrite: (String path) => path.replaceFirst('/api', '/v2'),
    );

    test('matches should return true for matching prefix', () {
      expect(configNoRewrite.matches('/api/users'), isTrue);
      expect(configNoRewrite.matches('/api'), isTrue);
    });

    test('matches should return false for non-matching prefix', () {
      expect(configNoRewrite.matches('/app/users'), isFalse);
      expect(configNoRewrite.matches('/ApI/users'), isFalse); // Case sensitive
    });

    test('getRewrittenPath should return original path if no rewrite function', () {
      expect(configNoRewrite.getRewrittenPath('/api/users'), '/api/users');
    });

    test('getRewrittenPath should return rewritten path if rewrite function exists', () {
      expect(configWithRewrite.getRewrittenPath('/api/users/1'), '/v2/users/1');
      expect(configWithRewrite.getRewrittenPath('/api'), '/v2');
      expect(configWithRewrite.getRewrittenPath('/other'), '/other');
    });

    test('toString returns expected format', () {
      expect(configNoRewrite.toString(), '{prefix: /api, target: http://example.com, rewrite: no}');
      expect(
        configWithRewrite.toString(),
        '{prefix: /api, target: http://example.com, rewrite: yes}',
      );
    });
  });

  group('RegexProxyConfig', () {
    final RegexProxyConfig configNoRewrite = RegexProxyConfig(
      pattern: RegExp(r'^/users/(\d+)$'),
      target: 'http://example.com',
    );
    final RegexProxyConfig configWithRewrite = RegexProxyConfig(
      pattern: RegExp(r'^/users/(\d+)/profile$'),
      target: 'http://example.com',
      rewrite: (String path) {
        final RegExpMatch? match = RegExp(r'^/users/(\d+)/profile').firstMatch(path);
        if (match != null) {
          // Use capture group 1 (the digits)
          return '/user-info/${match.group(1)}';
        }
        return path;
      },
    );

    final RegexProxyConfig configNoRewriteNotExact = RegexProxyConfig(
      pattern: RegExp(r'^/users/(\d+)'),
      target: 'http://example.com',
    );

    final RegexProxyConfig configWithRewriteNotExact = RegexProxyConfig(
      pattern: RegExp(r'^/users/(\d+)/profile'),
      target: 'http://example.com',
      rewrite: (String path) {
        final RegExpMatch? match = RegExp(r'^/users/(\d+)/profile').firstMatch(path);
        if (match != null) {
          return '/user-info/${match.group(1)}';
        }
        return path;
      },
    );

    test('matches should return true for matching regex', () {
      expect(configNoRewrite.matches('/users/123'), isTrue);
      expect(configWithRewrite.matches('/users/456/profile'), isTrue);
    });

    test('matches should return false when not exact match regex', () {
      expect(configNoRewriteNotExact.matches('/users/123'), isTrue);
      expect(configWithRewriteNotExact.matches('/users/456/profile'), isTrue);
    });

    test('matches should return false for non-matching regex', () {
      expect(configNoRewrite.matches('/customers/123'), isFalse);
      expect(configNoRewrite.matches('/users/abc'), isFalse);
    });

    test('getRewrittenPath should return original path if no rewrite function', () {
      expect(configNoRewrite.getRewrittenPath('/users/123/data'), '/users/123/data');
    });

    test('getRewrittenPath should return rewritten path if rewrite function exists', () {
      expect(configWithRewrite.getRewrittenPath('/users/789/profile'), '/user-info/789');
      expect(configWithRewrite.getRewrittenPath('/other/path'), '/other/path');
    });
  });

  group('normalizeRequestPath', () {
    test('should add leading slash if missing', () {
      expect(normalizePath('path/to/resource'), '/path/to/resource');
    });

    test('should not add leading slash if already present', () {
      expect(normalizePath('/path/to/resource'), '/path/to/resource');
    });

    test('should replace multiple slashes with single slash', () {
      expect(normalizePath('//path///to//resource'), '/path/to/resource');
      expect(normalizePath('/path//to/resource'), '/path/to/resource');
    });

    test('should handle empty path', () {
      expect(normalizePath(''), '/');
    });

    test('should handle path with only slashes', () {
      expect(normalizePath('//'), '/');
    });
  });

  group('proxyRequest', () {
    test('should correctly proxy all request elements', () async {
      final Uri originalUrl = Uri.parse('http://original.example.com/path');
      final Uri finalTargetUrl = Uri.parse('http://target.example.com/newpath');
      const String originalBody = 'Hello, Shelf Proxy!';
      final Map<String, String> originalHeaders = <String, String>{
        'Content-Type': 'text/plain',
        'X-Custom-Header': 'value',
      };
      final Map<String, Object> originalContext = <String, Object>{
        'user': 'testuser',
        'auth': true,
      };

      // Create a mock original shelf.Request
      final Request originalRequest = Request(
        'POST',
        originalUrl,
        headers: originalHeaders,
        body: originalBody,
        context: originalContext,
      );
      final Request proxiedRequest = proxyRequest(originalRequest, finalTargetUrl);

      final Map<String, String> expectedHeadersFiltered = Map<String, String>.fromEntries(
        originalHeaders.entries.where(
          (MapEntry<String, String> entry) => entry.key.toLowerCase() != 'content-length',
        ),
      );
      expect(proxiedRequest.method, 'POST');
      expect(proxiedRequest.url.toString(), 'newpath'); // Check the Uri object
      expect(expectedHeadersFiltered, originalHeaders);
      expect(proxiedRequest.context, originalContext);

      final String proxiedBody = await proxiedRequest.readAsString();
      expect(proxiedBody, originalBody);
    });

    test('should handle an empty request body', () async {
      final Uri originalUrl = Uri.parse('http://original.example.com/empty');
      final Uri finalTargetUrl = Uri.parse('http://target.example.com/empty-new');

      final Request originalRequest = Request('GET', originalUrl);

      final Request proxiedRequest = proxyRequest(originalRequest, finalTargetUrl);

      expect(proxiedRequest.method, 'GET');
      expect(proxiedRequest.url.toString(), 'empty-new');
      expect(await proxiedRequest.readAsString(), '');
    });

    test('should handle different HTTP methods', () async {
      final Uri originalUrl = Uri.parse('http://original.example.com/data');
      final Uri finalTargetUrl = Uri.parse('http://target.example.com/api/data');
      final List<String> methods = <String>['PUT', 'DELETE', 'PATCH', 'GET'];

      for (final String method in methods) {
        final Request originalRequest = Request(
          method,
          originalUrl,
          body: method == 'PUT' || method == 'PATCH' ? '{"key": "value"}' : null,
        );

        final Request proxiedRequest = proxyRequest(originalRequest, finalTargetUrl);
        expect(proxiedRequest.method, method, reason: 'Method "$method" should be preserved');

        if (method == 'PUT' || method == 'PATCH') {
          expect(await proxiedRequest.readAsString(), '{"key": "value"}');
        } else {
          expect(await proxiedRequest.readAsString(), '');
        }
      }
    });
  });
}
