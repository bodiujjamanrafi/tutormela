import assert from 'node:assert/strict'
import {initialRoute,postLoginRoute} from '../src/lib/navigation.js'
for(const hash of ['', '#', '#/'])assert.equal(initialRoute(hash),'browse')
for(const route of ['browse','subscriptions','tutor/test','password-reset','dashboard','editor/new','editor/123'])assert.equal(initialRoute('#/'+route),route)
assert.equal(initialRoute('#/feed'),'browse')
assert.equal(postLoginRoute('student'),'browse')
assert.equal(postLoginRoute('tutor'),'dashboard')
assert.equal(postLoginRoute('admin'),'dashboard')
console.log('Navigation checks passed: Find a tutor opens first, students return to search, tutors open their workspace, and direct links/recovery still work.')
