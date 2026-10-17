import sys, pathlib, unittest
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/'scripts'))
from compare_order import compare
class ComparisonChecks(unittest.TestCase):
    def setUp(self):
        self.rows=[{'ordinal':i,'localIdentifier':f'ID-{i}'} for i in range(1,21)]
        self.snapshot={'authorization':'full','members':self.rows}
    def test_moved_items_and_twenty_match(self):
        self.assertEqual(compare(self.snapshot,self.rows),[])
        moved=self.rows.copy(); moved[2],moved[14]=dict(moved[14],ordinal=3),dict(moved[2],ordinal=15)
        self.assertEqual(compare(self.snapshot,moved),[3,15])
    def test_missing_limited_duplicates_and_noncontiguous_never_pass(self):
        with self.assertRaises(ValueError): compare(self.snapshot,self.rows[:-1])
        with self.assertRaises(ValueError): compare(dict(self.snapshot,authorization='limited'),self.rows)
        duplicate=[dict(row,localIdentifier='same') for row in self.rows]
        with self.assertRaises(ValueError): compare(self.snapshot,duplicate)
        shifted=[dict(row,ordinal=row['ordinal']+1) for row in self.rows]
        with self.assertRaises(ValueError): compare(self.snapshot,shifted)
