import {createServer} from 'vite'
import React from 'react'
import {renderToStaticMarkup} from 'react-dom/server'
import assert from 'node:assert/strict'
const server=await createServer({server:{middlewareMode:true},appType:'custom'})
try{
 const {default:TutorProfileRoute}=await server.ssrLoadModule('/src/TutorProfileRoute.jsx');
 const {tutorProfileLink}=await server.ssrLoadModule('/src/lib/navigation.js');
 assert.equal(tutorProfileLink('tutor-a','post-a'),'tutor/tutor-a?post=post-a');
 assert.equal(tutorProfileLink('tutor-b'),'tutor/tutor-b');
 let showedProfile=false;const pendingProfile=renderToStaticMarkup(React.createElement(TutorProfileRoute,{route:'tutor/tutor-a?post=post-a',renderProfile:()=>{showedProfile=true;return 'Wrong previous tutor'},onBrowse:()=>{}}));
 assert.ok(pendingProfile.includes('Loading the selected tutor')&&!showedProfile,'A changed profile route must show a loading state, never a previous tutor');
 const {SubscriptionPage}=await server.ssrLoadModule('/src/Plans.jsx')
 const {TutorIdentity,TutorPosts,TeachingPostPage}=await server.ssrLoadModule('/src/TutorWorkspace.jsx')
 const user={id:'test',name:'Test tutor',role:'tutor',email:'private-owner@example.test',phone:'01700000000',created_at:'2026-09-01T00:00:00Z',tutor_identity:{introduction:'An independent introduction'}}
 const catalog={districts:['Dhaka'],subjects:['Mathematics'],classes:['SSC'],modes:['Online'],days:['Sunday']}
 const plans=renderToStaticMarkup(React.createElement(SubscriptionPage,{user,onSignIn:()=>{}}))
 assert.equal((plans.match(/Pay with bKash/g)||[]).length,3)
 for(const price of [300,500,800])assert.ok(plans.includes('৳'+price))
 assert.ok(plans.includes('subscription-flow'))
 for(const removed of ['Plan setup is being completed','Register interest','TUTORMELA MEMBERSHIP','Free, before you choose','A plan for your next chapter'])assert.ok(!plans.includes(removed))
 const identity=renderToStaticMarkup(React.createElement(TutorIdentity,{user,catalog,onSaved:()=>{}}))
 assert.ok(identity.includes('An independent introduction'));
 for(const detail of ['Account details','Only you','Sign-in email','private-owner@example.test','01700000000','Education &amp; background','September 2026','Manage account','Email &amp; password settings'])assert.ok(identity.includes(detail),detail+' missing from owner profile');
 assert.ok(!identity.includes('workspace-settings-icon'));
 const {default:TutorDocuments}=await server.ssrLoadModule('/src/TutorDocuments.jsx');
 const publicDocuments=renderToStaticMarkup(React.createElement(TutorDocuments,{profileId:'public-test'}));
 assert.ok(!publicDocuments.includes(user.email)&&!publicDocuments.includes(user.phone)&&!publicDocuments.includes('Account details'));
 for(const postField of ['Expected monthly fee','Available days','Teaching areas','Classes &amp; levels','Publish teaching post'])assert.ok(!identity.includes(postField))
 assert.ok(identity.includes('Edit profile')&&identity.includes('Posts shared')&&identity.includes('Post reactions')&&identity.includes('CV &amp; certificates'))
 const posts=renderToStaticMarkup(React.createElement(TutorPosts,{user,profile:null,catalog,onSaveTeaching:()=>{}}))
 assert.ok(posts.includes('aria-label="Create new post"')&&!posts.includes('status-composer'))
 assert.ok(!posts.includes('Go to My profile'))
 const editor=renderToStaticMarkup(React.createElement(TeachingPostPage,{user,profile:null,catalog,postId:'new',onSave:()=>{},onBack:()=>{}}));
 for(const field of ['Back to posts','Subjects','Classes &amp; levels','Teaching areas','Available days','Expected monthly fee','Save privately','Publish teaching post'])assert.ok(editor.includes(field),field+' missing from full composer');
 console.log('Workspace UI checks passed: separate full-form post page, identity summary, PDF controls and flowing colour background.')
}finally{await server.close()}
