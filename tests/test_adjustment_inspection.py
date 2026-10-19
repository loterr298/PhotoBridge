import datetime, importlib, pathlib, plistlib, sys, unittest
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'scripts'))


class AdjustmentInspectionChecks(unittest.TestCase):
    def setUp(self):
        self.module = importlib.import_module('inspect_adjustment')

    def fixture(self):
        return {'adjustmentTimestamp': datetime.datetime(2020, 1, 1),
                'adjustmentData': b'opaque-original-edit-recipe',
                'unknownVendorField': {'privateBytes': b'\x00\x01', 'flag': True}}

    def test_only_top_level_edit_timestamp_can_be_classified_as_timestamp_only(self):
        before = self.fixture(); after = self.fixture()
        after['adjustmentTimestamp'] = datetime.datetime(2026, 10, 19)
        result = self.module.analyze(plistlib.dumps(before), plistlib.dumps(after))
        self.assertEqual(result['classification'], 'ADJUSTMENT_TIMESTAMP_ONLY_DIFFERENCE')
        self.assertFalse(result['binaryIdentical'])
        self.assertEqual(result['changedTopLevelKeys'], ['adjustmentTimestamp'])
        self.assertFalse(result['strictByteVerificationPass'])

    def test_unknown_payload_change_or_type_change_never_counts_as_time_only(self):
        before = self.fixture()
        for replacement in [b'\x00\x02', 1]:
            after = self.fixture()
            after['adjustmentTimestamp'] = datetime.datetime(2026, 10, 19)
            if isinstance(replacement, bytes): after['unknownVendorField']['privateBytes'] = replacement
            else: after['unknownVendorField']['flag'] = replacement
            result = self.module.analyze(plistlib.dumps(before), plistlib.dumps(after))
            self.assertEqual(result['classification'], 'OTHER_PROPERTY_LIST_DIFFERENCE')
            self.assertFalse(result['strictByteVerificationPass'])

    def test_malformed_data_is_not_declared_equivalent(self):
        result = self.module.analyze(b'bad plist', plistlib.dumps(self.fixture()))
        self.assertEqual(result['classification'], 'UNPARSEABLE_PROPERTY_LIST')
        self.assertFalse(result['strictByteVerificationPass'])

    def test_duplicate_keys_cannot_hide_a_non_time_payload_change(self):
        def data(payload, year):
            return ('<?xml version="1.0"?><plist version="1.0"><dict><key>payload</key><string>' + payload +
                    '</string><key>payload</key><string>same</string><key>adjustmentTimestamp</key><date>' +
                    year + '-01-01T00:00:00Z</date></dict></plist>').encode()
        result = self.module.analyze(data('BAD', '2020'), data('XYZ', '2026'))
        self.assertEqual(result['classification'], 'AMBIGUOUS_PROPERTY_LIST')
        self.assertFalse(result['strictByteVerificationPass'])

    def test_unknown_xml_elements_cannot_hide_non_time_changes(self):
        def data(payload, year):
            return ('<plist version="1.0"><dict><unknown>' + payload +
                    '</unknown><key>adjustmentTimestamp</key><date>' + year +
                    '-01-01T00:00:00Z</date></dict></plist>').encode()
        result = self.module.analyze(data('BAD', '2020'), data('XYZ', '2026'))
        self.assertNotEqual(result['classification'], 'ADJUSTMENT_TIMESTAMP_ONLY_DIFFERENCE')

    def test_ignored_scalar_suffixes_cannot_hide_non_time_changes(self):
        for leaf in ['<data>YQ=={payload}</data>', '<date>2001-01-01T00:00:00Z{payload}</date>']:
            with self.subTest(leaf=leaf):
                def data(payload, year):
                    return ('<plist version="1.0"><dict><key>payload</key>' + leaf.format(payload=payload) +
                        '<key>adjustmentTimestamp</key><date>' + year + '-01-01T00:00:00Z</date></dict></plist>').encode()
                result = self.module.analyze(data('BAD', '2020'), data('XYZ', '2026'))
                self.assertNotEqual(result['classification'], 'ADJUSTMENT_TIMESTAMP_ONLY_DIFFERENCE')

    def test_scalar_normalization_cannot_hide_non_time_changes(self):
        for before_leaf, after_leaf in [('<date>2020-02-31T00:00:00Z</date>', '<date>2020-03-02T00:00:00Z</date>'),
                ('<real>1e999</real>', '<real>2e999</real>'), ('<real>1e-999</real>', '<real>2e-999</real>')]:
            def data(leaf, year):
                return ('<plist version="1.0"><dict><key>payload</key>' + leaf +
                    '<key>adjustmentTimestamp</key><date>' + year + '-01-01T00:00:00Z</date></dict></plist>').encode()
            result = self.module.analyze(data(before_leaf, '2020'), data(after_leaf, '2026'))
            self.assertNotEqual(result['classification'], 'ADJUSTMENT_TIMESTAMP_ONLY_DIFFERENCE')


if __name__ == '__main__': unittest.main()
