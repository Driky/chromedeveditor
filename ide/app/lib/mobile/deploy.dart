// Copyright (c) 2014, Google Inc. Please see the AUTHORS file for details.
// All rights reserved. Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

library spark.deploy;

import 'dart:async';

import 'package:chrome/chrome_app.dart' as chrome;

import 'adb.dart';
import '../jobs.dart';
import '../preferences.dart';
import '../tcp.dart';
import '../workspace.dart';
import '../workspace_utils.dart';

class DeviceInfo {
  final int vendorId;
  final int productId;
  /// This field is currently for debugging purposes only.
  /// It can be later used for more informative progress and error messages.
  final String description;

  DeviceInfo(this.vendorId, this.productId, this.description);
}

class HarnessPush {
  static final int ADB_PORT = 5037;
  final Container appContainer;
  final PreferenceStore _prefs;
  List<DeviceInfo> _knownDevices = [];

  HarnessPush(this.appContainer, this._prefs) {
    if (appContainer == null) {
      throw new ArgumentError('must provide an app to push');
    }

    final List permissions = chrome.runtime.getManifest()['permissions'];
    for (final p in permissions) {
      if (p is Map && (p as Map).containsKey('usbDevices')) {
        final List usbDevices = (p as Map)['usbDevices'];
        for (final Map<String, dynamic> d in usbDevices) {
          _knownDevices.add(
              new DeviceInfo(d['vendorId'], d['productId'], d['description']));
        }
      }
    }
  }

  List<int> _buildHttpRequest(String target, List<int> payload) {
    List<int> httpRequest = [];
    // Build the HTTP request headers.
    String boundary = '--------------------------------a921a8f557cf';
    String header =
        'POST /push?name=${appContainer.name}&type=crx HTTP/1.1\r\n'
        'User-Agent: Spark IDE\r\n'
        'Host: ${target}:2424\r\n'
        'Content-Type: multipart/form-data; boundary=$boundary\r\n';
    List<int> body = [];
    String bodyTop =
        '$boundary\r\n'
        'Content-Disposition: form-data; name="file"; '
        'filename="SparkPush.crx"\r\n'
        'Content-Type: application/octet-stream\r\n\r\n';
    body.addAll(bodyTop.codeUnits);

    // Add the CRX headers before the zip content.
    // This is the string "Cr24" then three little-endian 32-bit numbers:
    // - The version (2).
    // - The public key length (0).
    // - The signature length (0).
    // Since the App Harness/Chrome ADT on the other end doesn't check
    // the signature or key, we don't bother sending them.
    body.addAll([67, 114, 50, 52, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);

    // Now follows the actual zip data.
    body.addAll(payload);

    // Add the trailing boundary.
    body.addAll([13, 10]); // \r\n
    body.addAll(boundary.codeUnits);
    // Two trailing hyphens to indicate the final boundary.
    body.addAll([45, 45, 13, 10]); // --\r\n

    httpRequest.addAll(header.codeUnits);
    httpRequest.addAll('Content-length: ${body.length}\r\n\r\n'.codeUnits);
    httpRequest.addAll(body);

    return httpRequest;
  }

  /**
   * Packages (a subdirectory of) the current project, and sends it via HTTP to
   * a remote host.
   *
   * It expects the target host, and a [ProgressMonitor] for 10 units of work.
   * All files under the project will be added to a (slightly broken, see
   * below) CRX file, and sent via HTTP POST to the target host, using the /push
   * protocol described [here](https://github.com/MobileChromeApps/harness-push).
   *
   *     HarnessPush.push('192.168.1.121', monitor);
   *
   * Returns a Future for the push operation.
   *
   * Important Note: The CRX file that gets created and pushed is not correctly
   * signed and does not include the application's key. Since the target of a
   * push is intended to be a tool like the
   * [Chrome ADT](https://github.com/MobileChromeApps/harness) on Android,
   * and that tool doesn't care about the CRX metadata, this is not a problem.
   */
  Future pushToHost(String target, ProgressMonitor monitor) {
    monitor.start('Deploying…', 10);

    return _sendHttpPush(target, monitor);
  }

  Future _sendHttpPush(String target, ProgressMonitor monitor) {
    List<int> httpRequest;
    TcpClient client;
    return archiveContainer(appContainer).then((List<int> archivedData) {
      monitor.worked(3);
      httpRequest = _buildHttpRequest(target, archivedData);
      monitor.worked(5);
      return TcpClient.createClient(target, 2424);
    }).then((TcpClient _client) {
      client = _client;
      client.write(httpRequest);
      return client.stream.timeout(new Duration(minutes: 1)).first;
    }).then((List<int> responseBytes) {
      String response = new String.fromCharCodes(responseBytes);
      List<String> lines = response.split('\n');
      if (lines == null || lines.isEmpty) {
        return new Future.error('Bad response from push server');
      }

      if (lines.first.contains('200')) {
        monitor.worked(2);
      } else {
        return new Future.error(lines.first);
      }
    }).whenComplete(() {
      if (client != null) {
        client.dispose();
      }
    });
  }

  // Safe to call multiple times. It will open the device if it has not been opened yet.
  Future<AndroidDevice> _fetchAndroidDevice() {
    AndroidDevice device = new AndroidDevice(_prefs);

    Future doOpen(int index) {
      if (_knownDevices.length == 0) {
        return new Future.error('No known mobile devices.');
      }
      if (index >= _knownDevices.length) {
        return new Future.error('No known mobile device connected.\n'
            'Please check whether you plugged your mobile device properly.');
      }

      DeviceInfo di = _knownDevices[index];
      return device.open(di.vendorId, di.productId).catchError((e) {
        if ((e == 'no-device') || (e == 'no-connection')) {
          // No matching device found, try again.
          return doOpen(index + 1);
        } else {
          return new Future.error('Connection to the Android device failed.\n'
              'Please check whether "Developer Options" and "USB debugging" is enabled on your device.\n'
              'Enable Developer Options by going in Settings > System > About phone and press 7 times on Build number.\n'
              '"Developer options" should now appear in Settings > System > Developer options. '
              'You can now enable "USB debugging" in that menu.');
        }
      });
    }

    return doOpen(0).then((_) {
      return device.connect(new SystemIdentity()).catchError((e) {
        device.dispose();
        throw e;
      });
    }).then((_) => device);
  }

  Future pushAdb(ProgressMonitor monitor) {
    monitor.start('Deploying…', 10);

    // Try to find a local ADB server. If we fail, try to use USB.
    return _connectToAdbServer().then((client) {
      return _pushToAdbServer(client, monitor);
    }, onError: (_) { // No server found, so use our own USB code.
      return _pushViaUSB(monitor);
    });
  }

  Future<TcpClient> _connectToAdbServer() {
    // Try to connect to localhost:5037.
    return TcpClient.createClient(LOCAL_HOST, HarnessPush.ADB_PORT);
  }

  void _sendAdbCommand(TcpClient client, String msg) {
    // ADB expects a four-character ASCII hex string at the start of a message.
    // The value is the length of the rest of the message.
    String lenStr = msg.length.toRadixString(16);
    String padded = "0000".substring(lenStr.length);
    String payload = '${padded}${lenStr}${msg}';
    client.writeString(payload);
  }

  Future _pushToAdbServer(TcpClient client, ProgressMonitor monitor) {
    Stream<List<int>> stream = client.stream;

    // First, check how many devices there are connected.
    _sendAdbCommand(client, 'host:devices');

    return stream.take(1).single.then((List<int> deviceBytes) {
      String deviceList = new String.fromCharCodes(deviceBytes);
      if (!deviceList.startsWith('OKAY')) {
        return new Future.error('Invalid response to device list request');
      }

      // Drop the OKAY and four-character hex length off the beginning,
      // and then split on newlines. Each line is a device description.
      // Remove any trailing newline first.
      if (deviceList.endsWith('\n')) {
        deviceList = deviceList.substring(0, deviceList.length-2);
      }
      List<String> devices = deviceList.substring(8).split('\n');
      List<List<String>> deviceDetails = new List.from(
          devices.map((d) => d.split('\t')));

      // deviceDetails has one row for each device, and each device has two
      // columns: [0] is the serial number, [1] is the description.
      // TODO: Handle > 1 device!
      if (deviceDetails.length < 1) {
        return new Future.error(
            'Connected to ADB server, but there are no devices attached.');
      } else if (deviceDetails.length > 1) {
        return new Future.error(
            'Connect to ADB server, but there are multiple devices attached. FIXME TODO');
      } else {
        // The working case of exactly one device. We send a forwarding request
        // to the server.
        // Have to reconnect, these connections are single-use.
        return _connectToAdbServer().then((TcpClient client) {
          _sendAdbCommand(client,
              'host-serial:${ deviceDetails[0][0] }:forward:tcp:2424;tcp:2424');
          return _sendHttpPush('127.0.0.1', monitor);
        });
      }
    }, onError: (e) {
      return new Future.error(
          'Error reading response from ADB server: ' + e);
    });
  }


  Future _pushViaUSB(ProgressMonitor monitor) {
    List<int> httpRequest;
    AndroidDevice _device;

    // Build the archive.
    return archiveContainer(appContainer).then((List<int> archivedData) {
      monitor.worked(3);
      httpRequest = _buildHttpRequest('localhost', archivedData);
      monitor.worked(4);

      // Send this payload to the USB code.
      return _fetchAndroidDevice();
    }).then((deviceResult) {
      _device = deviceResult;

      return _device.sendHttpRequest(httpRequest, 2424).timeout(
          new Duration(minutes: 5), onTimeout: () {
            return new Future.error(
                'Push timed out: Total time exceeds 5 minutes');
          });
    }).then((msg) {
      monitor.worked(3);
      String resp = new String.fromCharCodes(msg);
      List<String> lines = resp.split('\r\n');
      Iterable<String> header = lines.takeWhile((l) => l.isNotEmpty);
      String body = lines.skip(header.length + 1).join('<br>\n');

      if (header.first.indexOf('200') < 0) {
        // Error! Fail with the error line.
        return new Future.error(
            '${header.first.substring(header.first.indexOf(' ') + 1)}: $body');
      } else {
        return body;
      }
    }).whenComplete(() {
      if (_device != null) _device.dispose();
    });
  }
}
