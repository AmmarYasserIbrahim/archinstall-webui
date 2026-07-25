import unittest
from unittest.mock import patch

import server


class ValidationTests(unittest.TestCase):
    @patch('server.discover_disk_devices', return_value={'/dev/sda', '/dev/nvme0n1'})
    def test_validate_device_path_valid(self, _mock_disks):
        server.validate_device_path('/dev/sda')

    @patch('server.discover_disk_devices', return_value={'/dev/sda'})
    def test_validate_device_path_rejects_unknown(self, _mock_disks):
        with self.assertRaises(ValueError):
            server.validate_device_path('/dev/sdb')

    @patch('server.discover_disk_devices', return_value={'/dev/sda'})
    def test_validate_payload_accepts_valid_data(self, _mock_disks):
        config = {
            'disk_config': {
                'device_modifications': [
                    {'device': '/dev/sda'}
                ]
            },
            'hostname': 'archlinux'
        }
        creds = {
            'users': [
                {'username': 'archuser'}
            ]
        }
        server.validate_payload(config, creds)

    @patch('server.discover_disk_devices', return_value={'/dev/sda'})
    def test_validate_payload_rejects_bad_username(self, _mock_disks):
        config = {
            'disk_config': {
                'device_modifications': [
                    {'device': '/dev/sda'}
                ]
            },
            'hostname': 'archlinux'
        }
        creds = {
            'users': [
                {'username': 'Invalid.User'}
            ]
        }
        with self.assertRaises(ValueError):
            server.validate_payload(config, creds)

    @patch('server.discover_disk_devices', return_value={'/dev/sda'})
    def test_validate_payload_rejects_invalid_hostname(self, _mock_disks):
        config = {
            'disk_config': {
                'device_modifications': [
                    {'device': '/dev/sda'}
                ]
            },
            'hostname': 'bad host name'
        }
        creds = {
            'users': [
                {'username': 'archuser'}
            ]
        }
        with self.assertRaises(ValueError):
            server.validate_payload(config, creds)


if __name__ == '__main__':
    unittest.main()
