#!/usr/bin/env python3
"""Checks that pipeline selection and release gates fail closed."""
import importlib.util, pathlib, unittest

def module(name):
    spec=importlib.util.spec_from_file_location(name,pathlib.Path(__file__).with_name(name+".py"))
    result=importlib.util.module_from_spec(spec);spec.loader.exec_module(result);return result

class PipelineTests(unittest.TestCase):
    def test_simulator_selection_never_switches_runtime(self):
        selection=module('select-simulator')
        devices={'ios26':[{'name':'iPhone 17','udid':'new','isAvailable':True}], 'ios17':[{'name':'iPhone 15','udid':'old','isAvailable':True}]}
        self.assertEqual(selection.select_device(devices,'ios17','iPhone'),'old')
        self.assertIsNone(selection.select_device(devices,'missing','iPhone'))
        self.assertIsNone(selection.select_device(devices,'ios26','iPhone','iPhone SE'))
    def test_runtime_patch_version_does_not_assume_identifier_format(self):
        selection=module('select-simulator')
        runtimes=[{'version':'26.4.1','identifier':'com.apple.CoreSimulator.SimRuntime.iOS-26-4','isAvailable':True}]
        self.assertEqual(selection.select_runtime(runtimes,'26.4.1'),'com.apple.CoreSimulator.SimRuntime.iOS-26-4')
        self.assertIsNone(selection.select_runtime(runtimes,'26.5'))
    def test_release_requires_exact_green_main_push(self):
        release=module('verify-release')
        run={'head_sha':'abc','event':'push','head_branch':'main','status':'completed','conclusion':'success'}
        self.assertTrue(release.has_green_run([run],'abc'))
        for changes in [{'head_sha':'other'},{'event':'pull_request'},{'head_branch':'feature'},{'status':'in_progress'},{'conclusion':'failure'}]:
            self.assertFalse(release.has_green_run([dict(run,**changes)],'abc'))
    def test_version_is_validated_before_shell_use(self):
        release=module('verify-release')
        self.assertEqual(release.validate_version('0.2.0'),'0.2.0')
        for value in ['v0.2.0','0.2','01.2.0','$(id)','0.2.0;echo secret']:
            with self.assertRaises(ValueError):release.validate_version(value)
    def test_missing_signing_settings_are_reported_by_name(self):
        preflight=module('release-preflight')
        self.assertEqual(preflight.missing_settings({}),preflight.REQUIRED)
        self.assertEqual(preflight.missing_settings({key:'present' for key in preflight.REQUIRED}),[])

if __name__ == '__main__':unittest.main()
