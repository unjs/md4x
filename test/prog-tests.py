#!/usr/bin/env python3
# -*- coding: utf-8 -*-

# How test/prog.py turns a --program argument into an argv. Every .txt suite
# and the pathological runner go through it, so a wrong split here fails ALL
# of them at once -- e.g. for a checkout whose path contains a space.
# (md4c 1407182 / 2bd1364.)
#
#   python3 prog-tests.py PATH/TO/md4x

import glob
import os
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch
from prog import Prog


class ProgramTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix='md4x prog ')
        self.addCleanup(directory.cleanup)
        self.directory = directory.name
        suffix = '.exe' if os.name == 'nt' else ''
        self.program = os.path.join(self.directory, 'md4x' + suffix)
        if os.name == 'nt':
            shutil.copy2(program, self.program)
            for library in glob.glob(os.path.join(os.path.dirname(program), '*.dll')):
                shutil.copy2(library, self.directory)
        else:
            os.symlink(program, self.program)

    def test_executable_path_with_spaces(self):
        command = self.program[:-4] if os.name == 'nt' else self.program
        result = Prog(command, '--format=text').to_html('*hello*\n')
        result[1] = result[1].replace('\r\n', '\n')
        self.assertEqual(result, [0, 'hello\n', b''])

    def test_command_options_override_defaults(self):
        # A legacy "program --opt" string still splits, and its own options
        # replace the defaults rather than adding to them.
        path = self.directory + os.pathsep + os.environ.get('PATH', '')
        with patch.dict(os.environ, {'PATH': path}):
            result = Prog('md4x --format=html', '--format=text').to_html(
                '*hello*\n')
        result[1] = result[1].replace('\r\n', '\n')
        self.assertEqual(result, [0, '<p><em>hello</em></p>\n', b''])


if __name__ == '__main__':
    program = os.path.abspath(sys.argv.pop(1))
    if os.name == 'nt' and not program.lower().endswith('.exe'):
        program += '.exe'
    unittest.main()
