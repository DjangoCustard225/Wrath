"""Build selection shared by packaging, icon compilation, and runtime audits."""
import os

VARIANT = os.environ.get('WRATH_VARIANT', 'modern')
if VARIANT not in ('modern', 'compatibility'):
    raise ValueError('WRATH_VARIANT must be modern or compatibility')
MINIMUM_IOS = '17.0' if VARIANT == 'compatibility' else '26.0'
