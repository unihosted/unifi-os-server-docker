"""Execute the workflow's matrix and manifest scripts without publishing images."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

WORKFLOW = (Path(__file__).resolve().parents[1] / '.github/workflows/build-image.yml').read_text()
VERSIONS = ['4.3.6', '5.0.6', '5.1.15', '5.1.19', '5.1.21', '5.1.37', '5.1.40', '5.1.42']


def step_script(name):
    step = WORKFLOW.split(f'      - name: {name}\n', 1)[1]
    block = step.split('        run: |\n', 1)[1]
    lines = []
    for line in block.splitlines():
        if line and not line.startswith('          '):
            break
        lines.append(line[10:])
    return '\n'.join(lines)


class BuildWorkflowTests(unittest.TestCase):
    def matrix(self, version='all', ref='refs/heads/test', amd64='', arm64='', success=True):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'output'
            result = subprocess.run(['bash', '-c', step_script('Build platform matrix')],
                                    env={**os.environ, 'GITHUB_REF': ref, 'REQUESTED_VERSION': version,
                                         'CUSTOM_URL_AMD64': amd64, 'CUSTOM_URL_ARM64': arm64,
                                         'GITHUB_OUTPUT': str(output)}, capture_output=True, text=True)
            self.assertEqual(result.returncode == 0, success, result.stderr)
            if not success:
                self.assertFalse(output.exists())
                return
            values = dict(line.split('=', 1) for line in output.read_text().splitlines())
            return json.loads(values['include']), values['latest_version']

    def test_all_versions_and_available_architectures(self):
        rows, latest = self.matrix()
        expected = [(v, arch) for v in VERSIONS for arch in ['amd64', 'arm64']
                    if (v, arch) != ('4.3.6', 'arm64')]
        self.assertEqual([(r['version'], r['arch_suffix']) for r in rows], expected)
        self.assertEqual(latest, '5.1.42')
        for row in rows:
            self.assertEqual(row['platform'], 'linux/' + row['arch_suffix'])
            self.assertIn('-' + row['version'] + '-', row['installer_url'])
            self.assertIn('linux-' + ('x64' if row['arch_suffix'] == 'amd64' else 'arm64'), row['installer_url'])

    def test_individual_versions_and_release_tags(self):
        for version in VERSIONS:
            with self.subTest(version=version):
                rows, latest = self.matrix(version)
                self.assertEqual(len(rows), 1 if version == '4.3.6' else 2)
                self.assertEqual({r['version'] for r in rows}, {version})
                self.assertEqual(latest, version)
                self.assertEqual(self.matrix(ref='refs/tags/v' + version), (rows, latest))

    def test_custom_installer_and_invalid_requests(self):
        rows, latest = self.matrix('9.0.0', arm64='https://example.com/installer')
        self.assertEqual(latest, '9.0.0')
        self.assertEqual(rows, [{'version': '9.0.0', 'platform': 'linux/arm64',
                                'arch_suffix': 'arm64', 'installer_url': 'https://example.com/installer'}])
        self.matrix('9.0.0', success=False)
        self.matrix(amd64='https://example.com/installer', success=False)

    def test_manifests_use_matching_sources_and_only_newest_is_latest(self):
        rows, latest = self.matrix()
        image = 'example.invalid/unifi'
        script = step_script('Create multi-arch manifest')
        script = script.replace('${{ steps.vars.outputs.ghcr_image }}', image)
        script = script.replace('${{ needs.matrix.outputs.include }}', json.dumps(rows))
        self.assertNotRegex(script, re.compile(r'\$\{\{'))
        with tempfile.TemporaryDirectory() as directory:
            calls = Path(directory) / 'calls'
            docker = Path(directory) / 'docker'
            docker.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$DOCKER_CALLS"\n')
            docker.chmod(0o755)
            result = subprocess.run(['bash', '-c', script],
                                    env={**os.environ, 'PATH': directory + os.pathsep + os.environ['PATH'],
                                         'DOCKER_CALLS': str(calls), 'LATEST_VERSION': latest},
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            commands = [line.split() for line in calls.read_text().splitlines()]
        self.assertEqual(len(commands), len(VERSIONS))
        for version, command in zip(VERSIONS, commands):
            expected = ['buildx', 'imagetools', 'create', '-t', f'{image}:{version}']
            if version == latest:
                expected += ['-t', f'{image}:latest']
            expected += [f'{image}:{version}-{row["arch_suffix"]}' for row in rows if row['version'] == version]
            self.assertEqual(command, expected)


if __name__ == '__main__':
    unittest.main()
